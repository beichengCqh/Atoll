/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// 投递目录的监听与解析。
///
/// 职责只有一条链路：目录里出现文件 → 解析成 `InboxMessage` → 交给 `onBatch` → 删掉文件。
/// 不碰 UI，不碰 store。写盘只发生在 `rejected/`（保留解析失败的现场）与删除已摄取的文件。
///
/// 线程模型：`start()` / `stop()` 可以从任意线程调用；内部状态一律只在私有串行队列上访问，
/// `onBatch` 也在该队列上被调用，调用方需要自己切回主线程再更新 UI。
final class InboxSpoolWatcher {

    // MARK: - 参数

    /// 保险丝扫描间隔。事件驱动之外的兜底，保证消息最多晚这么久被看到。
    private static let fallbackTickInterval: TimeInterval = 60

    /// 重建监听的退避起点与上限：0.1s 起步，每次翻倍，封顶 5s。
    private static let rearmInitialDelay: TimeInterval = 0.1
    private static let rearmMaxDelay: TimeInterval = 5

    /// JSON 解析失败后隔多久重试一次。
    private static let malformedRetryDelay: TimeInterval = 0.1

    // MARK: - 状态

    private let onBatch: ([InboxMessage]) -> Void
    private let queue = DispatchQueue(label: "com.dynamicisland.inbox.spool", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var tickTimer: DispatchSourceTimer?
    private var isRunning = false

    /// 当前的重建退避间隔，成功 arm 后归位到起点。
    private var rearmDelay: TimeInterval = InboxSpoolWatcher.rearmInitialDelay

    /// 删不掉的文件名。本会话内跳过它们，避免「扫描 → 解析 → 删除失败 → 下次再扫」空转。
    private var quarantined: Set<String> = []

    /// 解析失败的文件名 → 首次失败时间，用于「先重试一次再拒收」。
    private var malformedFirstSeen: [String: Date] = [:]

    /// 是否已经排了一次重试扫描，避免同一轮里堆出一串定时器。
    private var retryScanScheduled = false

    /// - Parameter onBatch: 每次扫描解析出的消息批次，在私有后台队列上调用。
    init(onBatch: @escaping ([InboxMessage]) -> Void) {
        self.onBatch = onBatch
    }

    deinit {
        // 关掉 source 才会走 cancel handler 把 fd close 掉
        source?.cancel()
        tickTimer?.cancel()
    }

    // MARK: - 生命周期

    /// 开始监听。重复调用无效果。
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// 停止监听并释放 fd 与定时器。停止后可以再次 `start()`。
    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        rearmDelay = Self.rearmInitialDelay

        // 顺序是关键：先挂上监听，再做首次扫描。
        // 反过来的话，「扫描完成到监听挂上」之间写入的文件不会触发事件，要等 60 秒保险丝才被发现。
        // 摄取语义是「读 → 回调 → 删文件」，天然幂等，所以先 arm 后 scan 即使重复读一次也没有副作用。
        armWatch()
        startFallbackTicker()

        // 首次扫描同时也是「Atoll 没运行期间堆积的消息」的补读入口
        scan()
        log("started, watching \(InboxLocation.spool.path)", category: .lifecycle)
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false

        source?.cancel()
        source = nil
        tickTimer?.cancel()
        tickTimer = nil

        // 显式重启是给删不掉、解析不了的文件一次新机会，所以两张表都清空
        quarantined.removeAll()
        malformedFirstSeen.removeAll()
        log("stopped", category: .lifecycle)
    }

    // MARK: - 监听

    /// 打开投递目录的 fd 并挂上监听，目录不存在时先建出来。
    ///
    /// 每次调用都先取消旧的 source。投递目录被 `rm -rf` 之后，旧 fd 会静默失明——
    /// 不报错，但再也收不到任何事件——唯一的出路是整套重建。
    private func armWatch() {
        source?.cancel()
        source = nil

        guard InboxLocation.ensureSpoolExists() else {
            scheduleRearm(reason: "cannot create spool directory")
            return
        }

        let fd = open(InboxLocation.spool.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRearm(reason: "open(O_EVTONLY) failed, errno \(errno)")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        src.setCancelHandler {
            close(fd)
        }

        source = src
        src.resume()
        rearmDelay = Self.rearmInitialDelay
    }

    /// 重建失败后的退避重试。投递目录可能只是被临时删掉，一直退避重试比放弃监听好。
    private func scheduleRearm(reason: String) {
        guard isRunning else { return }

        let delay = rearmDelay
        rearmDelay = min(rearmDelay * 2, Self.rearmMaxDelay)
        log("rearm in \(String(format: "%.1f", delay))s: \(reason)", category: .warning)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            // source 已经被别的路径重建好时就不用再来一遍
            guard let self, self.isRunning, self.source == nil else { return }
            self.armWatch()
            self.scan()
        }
    }

    /// 事件不带文件名，所以除了判断要不要重建监听，剩下的只能全量重扫。
    private func handleEvent() {
        let mask = source?.data ?? []

        // 目录本身被删掉或改名，当前 fd 指向的已经不是投递目录了。
        // `.revoke` 一并判掉：fd 被系统回收时同样要重建。
        if !mask.isDisjoint(with: [.delete, .rename, .revoke]) {
            log("spool directory replaced (mask \(mask.rawValue)), rebuilding watch", category: .warning)
            rearmDelay = Self.rearmInitialDelay
            armWatch()
        }

        scan()
    }

    /// 保险丝定时器。fd 失明、事件合并、休眠唤醒都可能让某次通知丢掉，兜底扫描保证消息还是会被看到。
    /// leeway 给足，让系统把它和别的定时器合并唤醒，省一点空转开销。
    private func startFallbackTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.fallbackTickInterval,
            repeating: Self.fallbackTickInterval,
            leeway: .seconds(10)
        )
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        tickTimer = timer
        timer.resume()
    }

    // MARK: - 扫描

    /// 全量重扫投递目录。
    ///
    /// 稳态下投递目录就是空的，而保险丝每 60 秒都会走到这里，所以空目录必须立刻返回：
    /// 这条路径上多做一点事，就是常驻的 CPU 开销。
    private func scan() {
        guard isRunning else { return }

        guard let contents = listSpool() else {
            // 目录列不出来，多半是被删了；此时挂着的 fd 已经收不到任何事件，得重建
            if source != nil {
                log("spool directory unreadable, rebuilding watch", category: .warning)
                armWatch()
            }
            return
        }

        let candidates = contents.filter(isDeliveryFile)
        guard !candidates.isEmpty else {
            malformedFirstSeen.removeAll()
            return
        }

        // 只保留仍在目录里的失败记录，避免这张表随着文件来去无限变长
        let presentNames = Set(candidates.map { $0.lastPathComponent })
        malformedFirstSeen = malformedFirstSeen.filter { presentNames.contains($0.key) }

        var delivered: [(url: URL, message: InboxMessage)] = []
        for url in enforceScanLimit(candidates) {
            switch parseDelivery(at: url) {
            case .message(let message):
                malformedFirstSeen[url.lastPathComponent] = nil
                delivered.append((url, message))
            case .malformed:
                handleMalformed(at: url)
            case .handled:
                continue
            }
        }

        guard !delivered.isEmpty else { return }

        // 先回调、后删文件：回调途中崩溃的话，下次扫描会重新读到同一个文件；
        // 消息 id 由文件名派生，store 侧按 id 覆盖，所以重复摄取不会多出一条。
        onBatch(delivered.map { $0.message })
        for item in delivered {
            deleteFile(item.url)
        }
        log("ingested \(delivered.count) delivery file(s)", category: .debug)
    }

    private func listSpool() -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: InboxLocation.spool,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        )
    }

    /// 只有 `.json` 结尾的文件算投递。
    /// `rules.json` 是打扰规则、不是消息，必须排除，否则会被当成消息读走并删掉。
    private func isDeliveryFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json" else { return false }
        let name = url.lastPathComponent
        guard name != InboxLocation.rulesFile.lastPathComponent else { return false }
        return !quarantined.contains(name)
    }

    /// 单次扫描的数量上限。长期没开 Atoll 时投递目录可能堆到几千个文件，全量解析会把 UI 更新一起拖住。
    ///
    /// 超限时按文件名排序保留最新的一批（README 建议的文件名以时间戳打头，名字序约等于时间序），
    /// 其余不解析直接删除，并记一条日志说明丢了多少条——静默截断是不可接受的。
    private func enforceScanLimit(_ files: [URL]) -> [URL] {
        guard files.count > InboxLocation.maxFilesPerScan else { return files }

        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let dropCount = sorted.count - InboxLocation.maxFilesPerScan
        for url in sorted.prefix(dropCount) {
            deleteFile(url)
        }
        log(
            "spool overflow: dropped \(dropCount) oldest delivery file(s) unparsed, kept newest \(InboxLocation.maxFilesPerScan)",
            category: .warning
        )
        return Array(sorted.suffix(InboxLocation.maxFilesPerScan))
    }

    // MARK: - 解析

    /// 单个投递文件的解析结果。
    private enum ParseOutcome {
        /// 解析成功。
        case message(InboxMessage)
        /// 内容不是合法 JSON 对象，交给「先重试一次再拒收」流程。
        case malformed
        /// 已经就地处理完（拒收的符号链接、超限文件、读的时候已经不在的文件），调用方无需再做什么。
        case handled
    }

    private func parseDelivery(at url: URL) -> ParseOutcome {
        let values = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        )

        // 投递目录对同一用户的任何进程可写。一个指向 ~/.ssh/id_rsa 的链接不该被读出来渲染到屏幕上，
        // 所以符号链接一律不读内容，查出来就删。
        if values?.isSymbolicLink == true {
            log("rejected symlink delivery: \(url.lastPathComponent)", category: .warning)
            deleteFile(url)
            return .handled
        }

        if let size = values?.fileSize, size > InboxLocation.maxFileSize {
            // 体积超限的文件不进 rejected/：那里按个数限流，一个几十兆的文件会把配额白白占住。
            // 文件名和体积记进日志，足够投递方定位是自己写错了对象。
            log(
                "rejected oversized delivery: \(url.lastPathComponent) is \(size) bytes, limit \(InboxLocation.maxFileSize)",
                category: .warning
            )
            deleteFile(url)
            return .handled
        }

        guard let data = try? Data(contentsOf: url) else {
            // 列目录到读取之间文件消失了：投递方自己清理或用户手动删掉，跳过即可
            return .handled
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = InboxMessage(
                  lenient: object,
                  fallbackID: url.deletingPathExtension().lastPathComponent,
                  fileDate: values?.contentModificationDate ?? Date()
              )
        else {
            return .malformed
        }

        return .message(message)
    }

    /// JSON 解析失败的处理：先给一次重试机会，仍然坏才挪进 `rejected/`。
    ///
    /// 坏 JSON 最常见的成因是投递方没守 README 里「先写临时文件再 rename」的契约，
    /// 于是正好读到写了一半的内容；隔一小会儿再读通常就是完整的了。
    private func handleMalformed(at url: URL) {
        let name = url.lastPathComponent

        guard let firstSeen = malformedFirstSeen[name] else {
            malformedFirstSeen[name] = Date()
            scheduleRetryScan()
            return
        }

        // 还没到重试点就留在原地，等已经排上的那次重扫
        guard Date().timeIntervalSince(firstSeen) >= Self.malformedRetryDelay else { return }

        malformedFirstSeen[name] = nil
        rejectFile(url)
    }

    private func scheduleRetryScan() {
        guard !retryScanScheduled else { return }
        retryScanScheduled = true
        queue.asyncAfter(deadline: .now() + Self.malformedRetryDelay) { [weak self] in
            guard let self else { return }
            self.retryScanScheduled = false
            self.scan()
        }
    }

    // MARK: - 文件处置

    /// 把解析不了的文件挪进 `rejected/` 保留现场，方便投递方自查。
    private func rejectFile(_ url: URL) {
        let name = url.lastPathComponent

        guard InboxLocation.ensureSpoolExists() else {
            quarantined.insert(name)
            log("cannot create rejected/, leaving \(name) in place", category: .error)
            return
        }

        pruneRejectedIfNeeded()

        let target = InboxLocation.rejected.appendingPathComponent(name)
        // 同名残留会让 moveItem 直接失败，先清掉
        try? FileManager.default.removeItem(at: target)

        do {
            try FileManager.default.moveItem(at: url, to: target)
            log("moved unparsable delivery to rejected/: \(name)", category: .warning)
        } catch {
            // 挪不动就隔离：文件留着当现场，本会话不再重复解析它
            quarantined.insert(name)
            log("failed to move \(name) into rejected/: \(error.localizedDescription)", category: .error)
        }
    }

    /// `rejected/` 超过上限时按文件名 FIFO 删掉最老的，给即将挪进来的这个文件腾出位置。
    private func pruneRejectedIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: InboxLocation.rejected,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return }

        let overflow = files.count + 1 - InboxLocation.maxRejectedFiles
        guard overflow > 0 else { return }

        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sorted.prefix(overflow) {
            try? fm.removeItem(at: url)
        }
    }

    /// 删除一个已处置完的投递文件。删不掉的进本会话隔离名单，后续扫描跳过。
    private func deleteFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // 文件已经不在了不算失败，只有还躺在目录里的才需要隔离，否则下一轮又会读到它
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            quarantined.insert(url.lastPathComponent)
            log("cannot delete \(url.lastPathComponent), quarantined for this session: \(error.localizedDescription)",
                category: .error)
        }
    }

    // MARK: - 日志

    /// 统一日志出口。
    ///
    /// 监听逻辑全程跑在后台队列，而 `Logger` 内部的 OSLog 缓存是一份没加锁的静态字典，
    /// 目前只被主线程访问。这里切回主线程再写，避免并发改动那份字典。
    private func log(_ message: String, category: LogCategory, function: String = #function, line: Int = #line) {
        DispatchQueue.main.async {
            Logger.log(
                "[InboxSpool] \(message)",
                category: category,
                file: #file,
                function: function,
                line: line
            )
        }
    }
}
