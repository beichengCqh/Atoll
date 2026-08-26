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
import os

/// 已摄取消息的内存表与磁盘存档。
///
/// 职责边界：只做数据合并、排序、淘汰、落盘，不监听目录（那是 `InboxSpoolWatcher` 的事），
/// 也不决定要不要弹横幅（那由 `ClaudeInboxManager` 依 `ingest` 的返回值判断）。
///
/// 内存表以折叠键（`source + key`）组织，同一个 session 在列表里始终只占一行。
/// 任何异常（存档损坏、目录消失、字段缺失）都降级处理后继续显示，
/// 静默丢消息比显示一条模糊消息糟得多。
@MainActor
final class InboxStore {
    /// 内存表容量上限。超出后按分级淘汰规则收敛。
    static let capacity = 200

    /// running 条目被视为陈旧的阈值：摄取后 24 小时仍停在 running，
    /// 说明投递方多半已经死了却没补终态，淘汰时它排在候选最后一档。
    static let staleRunningInterval: TimeInterval = 24 * 60 * 60

    /// 落盘防抖窗口：这段时间内的连续改动合并成一次写。
    private static let persistDebounce: TimeInterval = 1.5

    /// 落盘最长推迟时间。连续投递会不断把防抖窗口往后推，
    /// 超过这个时间就强制写一次，避免高频投递下存档永远写不出去。
    private static let persistMaxDeferral: TimeInterval = 10

    /// 存档格式版本，写进存档顶层的 `v`。
    private static let archiveVersion = 1

    /// 存档写入队列。串行，保证先后两次落盘不会互相覆盖成旧内容。
    private static let writeQueue = DispatchQueue(
        label: "com.ebullioscopic.Atoll.inbox.store",
        qos: .utility
    )

    private let logger = os.Logger(subsystem: "com.ebullioscopic.Atoll", category: "ClaudeInbox")

    /// 排好序的条目，供 UI 直接遍历：
    /// 先按 `status.sortRank`，同级按 `priority.sortRank`，再同级按 `timestamp` 倒序。
    private(set) var items: [InboxMessage] = []

    /// 折叠键 → 条目。真正的存储，`items` 是它排序后的投影。
    private var entries: [String: InboxMessage] = [:]

    /// 防抖中的落盘任务。
    private var persistTask: Task<Void, Never>?

    /// 最早一次尚未落盘的改动时间，`nil` 表示当前没有待写内容。
    private var pendingWriteSince: Date?

    /// 待处理的条数：状态属于待办（needs_input / idle）且未读。角标计数用它。
    /// 已过期的不计入——定期清理最长要等一个周期，角标不该在那之前显示一个陈旧数字。
    var pendingCount: Int {
        items.filter { $0.status.isPending && !$0.isRead && !$0.isExpired }.count
    }

    /// 正在运行的条数。同样跳过已过期的：会话被强杀时不会有 Stop 事件来收尾，
    /// 那条 running 只能靠 ttl 判定作废。
    var runningCount: Int {
        items.filter { $0.status == .running && !$0.isExpired }.count
    }

    // MARK: - 摄取

    /// 摄取一批消息，返回其中「新出现或发生了状态迁移」的条目（已是合并后的最终形态）。
    ///
    /// 调用方拿返回值决定要不要打扰人：状态没变的重复投递不在返回值里，
    /// 所以一个 session 反复上报 running 不会反复弹横幅。
    ///
    /// 一批里可能有同一折叠键的多条消息，先按 `timestamp` 升序处理，
    /// 保证最终留下的是最新那条，且中间的状态迁移都被识别到。
    @discardableResult
    func ingest(_ incoming: [InboxMessage]) -> [InboxMessage] {
        guard !incoming.isEmpty else { return [] }

        var changedKeys: Set<String> = []
        // 时间早的先应用，同一时刻的按紧急度倒序——越紧急的越后应用，因而赢得覆盖。
        // 次键不能省：投递方按 README 用秒精度时间戳时同一秒内会有多条，
        // 而目录枚举顺序未定义，没有确定性次键的话 running 有概率盖掉 needs_input。
        for message in incoming.sorted(by: Self.applyOrder) {
            apply(message, changedKeys: &changedKeys)
        }

        enforceCapacity()
        rebuildItems()
        persist()

        // 被 cleared 撤回或刚好被淘汰掉的条目不再返回，
        // 避免为一条已经不在列表里的消息弹横幅
        return items.filter { changedKeys.contains($0.collapseKey) }
    }

    /// 把单条消息合并进内存表；`changedKeys` 收集需要通知调用方的折叠键。
    private func apply(_ message: InboxMessage, changedKeys: inout Set<String>) {
        let key = message.collapseKey

        guard let existing = entries[key] else {
            // 撤回一个本就不存在的条目，什么都不用做
            guard message.status != .cleared else { return }
            var fresh = message
            fresh.isRead = false
            fresh.receivedAt = .now
            entries[key] = fresh
            changedKeys.insert(key)
            return
        }

        // 乱序保护：文件系统事件可能乱序到达，晚到的旧消息不该把新状态盖回去。
        // 撤回同样受这条约束——后面还有更新的消息，说明这个 key 仍然活着。
        guard message.timestamp >= existing.timestamp else { return }

        guard message.status != .cleared else {
            entries.removeValue(forKey: key)
            changedKeys.remove(key)
            return
        }

        var merged = message
        merged.receivedAt = .now

        // 状态变了当然算新事件。除此之外还有一种必须当作新事件的情况：
        // 同一个会话连着问第二个问题——状态同样是 needs_input，但那是一个新问题，
        // 不提醒的话行内容会被悄悄换掉，已读态还留着，人就永远不知道被问了第二次。
        // id 由投递文件名派生，逐条唯一，用它区分「新的一问」与「同一条重投」。
        let statusChanged = existing.status != message.status
        let newQuestion = message.status == .needsInput && existing.id != message.id
        let isNewEvent = statusChanged || newQuestion

        merged.isRead = isNewEvent ? false : existing.isRead
        entries[key] = merged
        if isNewEvent { changedKeys.insert(key) }
    }

    // MARK: - 已读与删除

    /// 标记单条为已读。`id` 是投递文件级的消息 id，找不到对应条目就什么都不做。
    func markRead(id: String) {
        guard let key = collapseKey(forID: id), entries[key]?.isRead == false else { return }
        entries[key]?.isRead = true
        rebuildItems()
        persist()
    }

    /// 全部标记为已读。角标随之归零，条目仍留在列表里。
    func markAllRead() {
        guard entries.values.contains(where: { !$0.isRead }) else { return }
        entries = entries.mapValues { entry in
            var updated = entry
            updated.isRead = true
            return updated
        }
        rebuildItems()
        persist()
    }

    /// 删除单条。
    func remove(id: String) {
        guard let key = collapseKey(forID: id) else { return }
        entries.removeValue(forKey: key)
        rebuildItems()
        persist()
    }

    /// 清空列表。
    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        rebuildItems()
        persist()
    }

    /// 按消息 id 反查折叠键。id 每次投递都不同，而内存表按折叠键组织，
    /// UI 回传的 id 需要在这里转一次。
    private func collapseKey(forID id: String) -> String? {
        entries.first { $0.value.id == id }?.key
    }

    // MARK: - 排序与容量

    /// 重排 `items`。任何改动 `entries` 的操作结束后都要调一次。
    private func rebuildItems() {
        items = Self.sorted(Array(entries.values))
    }

    /// 排序规则：状态桶 → 优先级 → 时间倒序 → 折叠键。
    /// 最后一级用折叠键收尾，保证同秒到达的条目每次排出的顺序一致，列表不会自己抖动。
    nonisolated private static func sorted(_ input: [InboxMessage]) -> [InboxMessage] {
        input.sorted { left, right in
            if left.status.sortRank != right.status.sortRank {
                return left.status.sortRank < right.status.sortRank
            }
            if left.priority.sortRank != right.priority.sortRank {
                return left.priority.sortRank < right.priority.sortRank
            }
            if left.timestamp != right.timestamp {
                return left.timestamp > right.timestamp
            }
            return left.collapseKey < right.collapseKey
        }
    }

    /// 超出容量时分级淘汰，逐档扫过去直到降到上限以内：
    /// 已过期 → 已读终态 → 未读终态 → info → 陈旧 running；仍超限就只保留最新的若干条。
    ///
    /// 活着的 needs_input 全程受保护，宁可超出上限也不淘汰——
    /// 那是唯一真正在等人回话的状态，丢掉它等于让北城错过提醒。
    private func enforceCapacity() {
        guard entries.count > Self.capacity else { return }

        let limit = Self.capacity
        let staleAfter = Self.staleRunningInterval
        let now = Date()
        var survivors = Array(entries.values)

        let tiers: [(InboxMessage) -> Bool] = [
            { $0.isExpired },
            { $0.isRead && $0.status.isTerminal },
            { $0.status.isTerminal },
            { $0.status == .info },
            { $0.status == .running && now.timeIntervalSince($0.receivedAt) > staleAfter }
        ]

        for matches in tiers {
            guard survivors.count > limit else { break }
            // 同一档内先淘汰最老的
            let doomed = survivors
                .filter { matches($0) && !Self.isProtected($0) }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(survivors.count - limit)
            guard !doomed.isEmpty else { continue }
            let doomedKeys = Set(doomed.map(\.collapseKey))
            survivors.removeAll { doomedKeys.contains($0.collapseKey) }
        }

        if survivors.count > limit {
            let protected = survivors.filter(Self.isProtected)
            let others = survivors
                .filter { !Self.isProtected($0) }
                .sorted { $0.timestamp > $1.timestamp }
            survivors = protected + others.prefix(max(0, limit - protected.count))
        }

        entries = Dictionary(
            survivors.map { ($0.collapseKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 摄取时的应用顺序：时间升序，同一时刻按紧急度倒序，
    /// 使最紧急的那条最后应用、最终留在表里。
    nonisolated private static func applyOrder(_ lhs: InboxMessage, _ rhs: InboxMessage) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.status.sortRank > rhs.status.sortRank
    }

    /// 受保护条目：还没过期的 needs_input。淘汰逻辑任何一档都不碰它。
    nonisolated private static func isProtected(_ message: InboxMessage) -> Bool {
        message.status == .needsInput && !message.isExpired
    }

    /// 清掉所有已过期条目，返回清掉的条数。
    ///
    /// 容量淘汰只在条目超上限时才跑，所以 ttl 不能只挂在那条路径上：
    /// 进程被 `kill -9` 时 Stop 事件不会触发，那条 running 会永远停在列表里，
    /// 收起态的刘海上就挂着一个永不消失的计数。投递方给 running 配了 12 小时 ttl
    /// 正是为了兜住这种情况，需要有人定期来收。
    @discardableResult
    func pruneExpired() -> Int {
        let doomed = entries.filter { $0.value.isExpired }
        guard !doomed.isEmpty else { return 0 }

        for key in doomed.keys {
            entries.removeValue(forKey: key)
        }
        rebuildItems()
        logger.log("[Inbox] 清理 \(doomed.count) 条已过期条目：\(doomed.values.map(\.key).joined(separator: ", "))")
        return doomed.count
    }

    // MARK: - 持久化

    /// 从磁盘读回上次的存档。
    /// 文件不存在、JSON 损坏、字段缺失一律当空表处理，不报错也不中断启动。
    func load() {
        entries = [:]
        defer { rebuildItems() }

        guard let data = try? Data(contentsOf: InboxLocation.storeFile) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            logger.error("[Inbox] 存档解析失败，按空表启动")
            return
        }

        for raw in Self.archivedElements(in: root) {
            guard let dict = raw as? [String: Any],
                  let message = Self.message(fromArchive: dict) else { continue }
            // cleared 是撤回指令而不是可展示的条目，存档里混进来就丢掉
            guard message.status != .cleared else { continue }
            // 同折叠键重复出现时保留时间较新的那条
            if let existing = entries[message.collapseKey], existing.timestamp > message.timestamp {
                continue
            }
            entries[message.collapseKey] = message
        }

        enforceCapacity()
    }

    /// 请求落盘。高频调用下做防抖合并，避免每条消息都写一次磁盘；
    /// 连续投递不断刷新防抖窗口时，最多推迟 `persistMaxDeferral` 秒就强制写一次。
    func persist() {
        let now = Date()
        let since = pendingWriteSince ?? now
        pendingWriteSince = since

        guard now.timeIntervalSince(since) < Self.persistMaxDeferral else {
            writeToDisk()
            return
        }

        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.persistDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    /// 立刻把待写内容落盘，写完才返回。停止监听、应用退出等时机调用。
    ///
    /// 必须同步写：进程退出时后台队列上排着的块不会再被执行，
    /// 用异步写等于把最后一批消息丢在防抖窗口里——而那批往往正是北城最需要看到的。
    func flushPendingWrite() {
        guard pendingWriteSince != nil else { return }
        writeToDisk(synchronously: true)
    }

    /// 序列化当前内存表并写盘。
    /// 序列化在主线程做（几百条量级足够快）；文件 IO 默认放后台不卡 UI，
    /// `synchronously` 为真时就地写完再返回，供退出前的收尾使用。
    private func writeToDisk(synchronously: Bool = false) {
        persistTask?.cancel()
        persistTask = nil
        pendingWriteSince = nil

        let payload: [String: Any] = [
            "v": Self.archiveVersion,
            "items": items.map(Self.archiveDictionary(for:))
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            logger.error("[Inbox] 存档序列化失败，本次跳过落盘")
            return
        }

        let capturedLogger = logger
        if synchronously {
            Self.writeQueue.sync {
                Self.writeAtomically(data, logger: capturedLogger)
            }
        } else {
            Self.writeQueue.async {
                Self.writeAtomically(data, logger: capturedLogger)
            }
        }
    }

    /// 原子写：先写同目录临时文件再 rename，读取方永远看不到写了一半的存档。
    /// 失败只记日志——存档丢的是重启后的历史，内存里的消息不受影响。
    nonisolated private static func writeAtomically(_ data: Data, logger: os.Logger) {
        guard InboxLocation.ensureStoreDirectoryExists() else {
            logger.error("[Inbox] 存档目录不可用，跳过落盘")
            return
        }

        let target = InboxLocation.storeFile
        let temporary = target
            .deletingLastPathComponent()
            .appendingPathComponent("store.json.tmp-\(UUID().uuidString)")
        let fileManager = FileManager.default

        do {
            try data.write(to: temporary)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            logger.error("[Inbox] 存档落盘失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 取出存档里的条目数组。同时接受 `{"v":1,"items":[...]}` 与裸数组两种形态，
    /// 手写或早期版本的存档也能读回来。
    nonisolated private static func archivedElements(in root: Any) -> [Any] {
        if let object = root as? [String: Any] {
            return object["items"] as? [Any] ?? []
        }
        return root as? [Any] ?? []
    }

    /// 存档条目 → 消息。
    ///
    /// 复用投递文件那套宽松解码，于是「字段缺失、类型不符一律降级」的容忍规则
    /// 在存档路径与投递路径上完全一致，只多认 `read` / `received` 两个字段。
    /// 顶层不是字典时返回 `nil`，由调用方跳过该条。
    nonisolated private static func message(fromArchive dict: [String: Any]) -> InboxMessage? {
        let storedID = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = (storedID?.isEmpty == false ? storedID : nil) ?? UUID().uuidString
        let received = (dict["received"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .now

        guard var message = InboxMessage(lenient: dict, fallbackID: fallbackID, fileDate: received) else {
            return nil
        }
        message.isRead = (dict["read"] as? Bool) ?? false
        message.receivedAt = received
        return message
    }

    /// 消息 → 存档条目。字段名与投递文件保持一致，
    /// 存档里的一条可以直接拷出来当投递样例用，排查问题时不用做格式转换。
    nonisolated private static func archiveDictionary(for message: InboxMessage) -> [String: Any] {
        // 投递方声明过更高的 schema 版本时，写回一个高于当前支持版本的 v，
        // 读回来才能重新推出 isFutureVersion，UI 上的「格式较新」标记不会因重启丢失
        let version = message.isFutureVersion
            ? InboxMessage.supportedVersion + 1
            : InboxMessage.supportedVersion

        var dict: [String: Any] = [
            "v": version,
            "id": message.id,
            "key": message.key,
            "source": message.source,
            "status": message.status.rawValue,
            "title": message.title,
            "present": message.presentation.rawValue,
            "priority": message.priority.rawValue,
            "ts": message.timestamp.timeIntervalSince1970,
            "read": message.isRead,
            "received": message.receivedAt.timeIntervalSince1970
        ]
        if let detail = message.detail { dict["detail"] = detail }
        if let cwd = message.cwd { dict["cwd"] = cwd }
        if let icon = message.icon { dict["icon"] = icon }
        if let ttl = message.ttl { dict["ttl"] = ttl }
        if !message.tags.isEmpty { dict["tags"] = message.tags }
        return dict
    }
}
