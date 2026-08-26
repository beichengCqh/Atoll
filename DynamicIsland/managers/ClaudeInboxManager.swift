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

import Combine
import Defaults
import Foundation
import SwiftUI

/// 投递链路的健康度，三态。
///
/// 空角标本身有歧义：可能是"确实没待办"，也可能是"投递方根本没在跑"。
/// 这两种情况在界面上必须落到不同的像素，否则一个坏掉的 hook 会伪装成"一切正常"，
/// 而北城会一直等一条永远不会来的消息。本枚举就是为了把这两种情况分开。
enum InboxSignalHealth: Equatable {
    /// 最近收到过投递，链路通畅。
    case healthy
    /// 从未收到过任何投递，多半是投递方还没配。
    case neverReceived
    /// 距上次投递已超过阈值，链路可能已经失效。关联值是上次收到投递的时刻。
    case stale(since: Date)

    /// 是否需要在界面上给出提示。`healthy` 之外都要提示。
    var needsAttention: Bool { self != .healthy }

    /// 一行提示文案，供设置页与列表页头部直接显示。
    var localizedHint: String {
        switch self {
        case .healthy:
            return String(localized: "Delivery is working")
        case .neverReceived:
            return String(localized: "No delivery received yet — the sender may not be set up")
        case .stale:
            return String(localized: "No delivery for a long time — the sender may have stopped")
        }
    }
}

/// 横幅限流器。两条限制同时生效，任何一条不满足都不弹。
///
/// 按折叠键限流防的是同一个 session 反复改状态时刷屏；
/// 全局限流防的是多个 session 同时结束时横幅排队糊在屏幕上。
private struct SneakPeekLimiter {
    /// 同一折叠键两次横幅之间的最小间隔。
    static let perKeyInterval: TimeInterval = 60
    /// 不分来源的全局最小间隔。
    static let globalInterval: TimeInterval = 10
    /// 记账表容量上限。超出后清掉已过窗口的键，避免长期运行内存只增不减。
    private static let maxTrackedKeys = 256

    private var lastShownByKey: [String: Date] = [:]
    private var lastShownGlobally: Date?

    /// 判断此刻是否允许为 `collapseKey` 弹一次横幅。
    ///
    /// 放行时会同时记账，因此同一次判定只能调用一次；调用方拿到 `true` 后必须真的把横幅弹出去，
    /// 否则这一次配额就被白白吃掉了。
    mutating func allow(_ collapseKey: String, now: Date = .now) -> Bool {
        if let last = lastShownGlobally, now.timeIntervalSince(last) < Self.globalInterval {
            return false
        }
        if let last = lastShownByKey[collapseKey], now.timeIntervalSince(last) < Self.perKeyInterval {
            return false
        }
        lastShownByKey[collapseKey] = now
        lastShownGlobally = now
        if lastShownByKey.count > Self.maxTrackedKeys {
            prune(now: now)
        }
        return true
    }

    /// 清空全部记账。功能关闭再打开时调用，让重新启用后的第一条消息立刻能弹。
    mutating func reset() {
        lastShownByKey.removeAll()
        lastShownGlobally = nil
    }

    /// 丢掉已经过了限流窗口的键——它们下次一定放行，留着只占内存。
    private mutating func prune(now: Date) {
        lastShownByKey = lastShownByKey.filter { now.timeIntervalSince($0.value) < Self.perKeyInterval }
    }
}

/// Claude inbox 的对外门面：串起投递目录监听、条目存储与"要不要打扰北城"的判定。
///
/// 职责边界：只收、只显示、由北城手动已读清理。不查任何外部进程死活，不轮询外部状态，
/// 不往投递方回写任何东西。所有对外状态都是只读的 `@Published`，UI 层不能反向改它们。
@MainActor
final class ClaudeInboxManager: ObservableObject {
    static let shared = ClaudeInboxManager()

    /// 超过这个时长没有收到任何投递，就判定链路"可能已失效"。
    static let staleSignalThreshold: TimeInterval = 6 * 60 * 60

    /// 健康度是从时间推导出来的，没有新事件也会随时间变化，
    /// 所以要按这个间隔主动通知界面重算，否则"长时间无信号"永远不会出现在屏幕上。
    private static let healthTickInterval: TimeInterval = 300

    /// 当前全部条目，已由 store 排好序（待确认在前）。
    @Published private(set) var items: [InboxMessage] = []

    /// 最近一次收到任何投递的时刻。`nil` 表示本次运行与历史记录里都没有过投递。
    @Published private(set) var lastSignalAt: Date?

    private let store = InboxStore()
    private var watcher: InboxSpoolWatcher?
    private var limiter = SneakPeekLimiter()
    private var cancellables = Set<AnyCancellable>()
    private var healthTicker: Task<Void, Never>? { didSet { oldValue?.cancel() } }

    private init() {
        observeSettings()
    }

    // MARK: - 对外只读状态

    /// 待北城处理的未读条数。
    var pendingCount: Int { store.pendingCount }

    /// 正在运行的条数。
    var runningCount: Int { store.runningCount }

    /// 收起态是否要显示角标。
    var hasBadge: Bool { pendingCount + runningCount > 0 }

    /// 角标旁的一行摘要，形如 `2 待确认 · 1 运行中`。
    /// 只有一类时只显示那一类，两类都为 0 时返回空串，调用方据此决定要不要占位。
    ///
    /// 待确认这一桶包含 `needsInput` 与 `idle` 两种状态，标签统一取"待确认"这个更强的说法，
    /// 因为两者对北城的意义相同：得去看一眼。
    var badgeSummary: String {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append("\(pendingCount) \(InboxStatus.needsInput.localizedLabel)")
        }
        if runningCount > 0 {
            parts.append("\(runningCount) \(InboxStatus.running.localizedLabel)")
        }
        return parts.joined(separator: " · ")
    }

    /// 投递链路健康度。界面必须把它和"没有待办"区分显示。
    var signalHealth: InboxSignalHealth {
        guard let lastSignalAt else { return .neverReceived }
        if Date().timeIntervalSince(lastSignalAt) > Self.staleSignalThreshold {
            return .stale(since: lastSignalAt)
        }
        return .healthy
    }

    // MARK: - 生命周期

    /// 开始监听投递目录并载入已存条目。功能开关关闭时直接返回，重复调用无副作用。
    func start() {
        guard Defaults[.enableClaudeInbox] else { return }
        guard watcher == nil else { return }

        // 目录建不出来也继续走：watcher 自己会退避重试，条目该显示还是要显示
        if !InboxLocation.ensureSpoolExists() {
            Logger.log("[Inbox] Spool directory unavailable at \(InboxLocation.spool.path)", category: .warning)
        }

        store.load()
        items = store.items
        lastSignalAt = restoredLastSignal()

        // watcher 强持有这个闭包，闭包只弱引用回来，避免 manager ←→ watcher 互相咬住
        let created = InboxSpoolWatcher { [weak self] batch in
            // 回调发生在 watcher 的后台队列，必须切回主线程再碰 store 与 @Published。
            //
            // 这里必须是 `sync`：watcher 在回调返回后立刻删除投递文件，
            // 用 `Task {}` 的话回调会立即返回，文件在消息入库之前就被删掉，
            // 中途任何一次提前 return（功能开关被关、进程退出）都会让这批消息凭空消失。
            // 扫描只在 watcher 的私有队列上跑，主线程从不反过来等它，因此不构成死锁。
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.handleBatch(batch)
                }
            }
        }
        watcher = created
        created.start()
        startHealthTicker()

        Logger.log("[Inbox] Started, \(items.count) item(s) restored", category: .lifecycle)
    }

    /// 停止监听并把当前条目落盘。可重复调用。
    ///
    /// 落盘走 `flushPendingWrite` 而不是 `persist`：后者只是重新武装防抖计时器，
    /// 进程随后退出的话那次推迟的写入永远不会发生。
    func stop() {
        watcher?.stop()
        watcher = nil
        healthTicker = nil
        store.flushPendingWrite()
        Logger.log("[Inbox] Stopped", category: .lifecycle)
    }

    // MARK: - 用户操作

    /// 标记单条已读。已读条目不再计入角标，但仍留在列表里。
    func markRead(id: String) {
        store.markRead(id: id)
        syncAndPersist()
    }

    /// 全部标记已读。
    func markAllRead() {
        store.markAllRead()
        syncAndPersist()
    }

    /// 删除单条。列表里划掉某条时调用。
    func remove(id: String) {
        store.remove(id: id)
        syncAndPersist()
    }

    /// 清空全部条目。删除只会由用户手动触发，摄取链路自身从不删条目。
    func clearAll() {
        store.removeAll()
        syncAndPersist()
    }

    /// 往投递目录写一条自检消息，用来验证"投递 → 摄取 → 显示"整条链路是通的。
    ///
    /// 走的是和外部投递方完全相同的原子写路径，所以这条自检真的能证明链路可用。
    /// 消息状态是 `info`，因此它只出现在展开后的列表里，不弹横幅也不增加角标；
    /// 界面上更快的验证信号是健康度立刻变成"正常"。
    func sendTestDelivery() {
        let payload: [String: Any] = [
            "v": 1,
            "status": "info",
            "title": String(localized: "Atoll inbox self-test"),
            "detail": String(localized: "Delivery, ingest and display are working."),
            "source": "atoll",
            "key": "self-test",
            "ts": Date().timeIntervalSince1970,
            "present": "badge",
            "ttl": 600
        ]
        do {
            try writeDelivery(payload)
        } catch {
            Logger.log("[Inbox] Test delivery failed: \(error.localizedDescription)", category: .error)
        }
    }

    // MARK: - 摄取

    /// 处理一批投递。调用方保证已在主线程。
    private func handleBatch(_ batch: [InboxMessage]) {
        // 关闭功能后仍可能有一批在途事件到达，这里兜住，不让它改动已清空的状态
        guard Defaults[.enableClaudeInbox] else { return }

        // 只要收到投递就算链路有信号，哪怕整批都被折叠掉、一条都没进列表
        lastSignalAt = .now

        // ingest 内部已经排了落盘，这里只把结果同步到 @Published
        let changed = store.ingest(batch)
        items = store.items

        for message in changed {
            presentIfAllowed(message)
        }
    }

    /// 对一条刚出现或刚发生状态迁移的消息做打扰判定，通过则弹一次瞬时横幅。
    private func presentIfAllowed(_ message: InboxMessage) {
        guard shouldInterrupt(for: message) else { return }
        guard limiter.allow(message.collapseKey) else { return }

        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .claudeInbox,
            duration: Defaults[.inboxSneakPeekDuration],
            value: 0,
            icon: message.resolvedIcon,
            title: message.title,
            subtitle: sneakSubtitle(for: message),
            accentColor: message.status.tint
        )
    }

    /// 打扰判定。任何一条不满足就返回 false，消息降级为只更角标与列表，绝不丢弃。
    ///
    /// 判定顺序是固定的：先看北城的总开关与投递方的意愿，再看当下的场景（静音、勿扰），
    /// 限流放在最后，由调用方在这之后执行——因为限流会记账，不能在前面的门禁上白吃配额。
    private func shouldInterrupt(for message: InboxMessage) -> Bool {
        // 1. 总开关
        guard Defaults[.enableClaudeInbox] else { return false }
        // 2. 投递方逐条声明的呈现等级。它说了不要打扰就绝不打扰，Atoll 只能降级不能升级
        guard message.presentation >= .sneak else { return false }
        // 3. 只有"等着人"和"已经死了"这两种状态值得打断。
        //    完成与运行中更角标就够了，抬头看一眼即可，不必打断手上的事。
        guard message.status == .needsInput || message.status == .failed else { return false }
        // 4. 静音期。静音只压横幅，摄取与角标照常
        guard Defaults[.inboxMutedUntil] <= Date() else { return false }
        // 5. 系统勿扰/专注模式开启时降级，跟随系统的意愿
        guard !DoNotDisturbManager.shared.isDoNotDisturbActive else { return false }
        return true
    }

    /// 横幅副标题：优先给项目目录名，让北城一眼看出是哪个仓在等他；没有 cwd 时退回来源名。
    /// 不用 detail，因为它可能长达两千字，横幅放不下。
    private func sneakSubtitle(for message: InboxMessage) -> String {
        if let cwd = message.cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return message.source
    }

    // MARK: - 设置观察

    /// 观察功能开关。关掉时立即停止监听并清空对外状态，避免残留角标误导北城。
    private func observeSettings() {
        Defaults.publisher(.enableClaudeInbox, options: [])
            // KVO 可能从非主线程投递（外部 defaults write、后台线程改键），
            // 而下面要碰 @Published 与 watcher 生命周期，必须先落到主线程
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.limiter.reset()
                    self.start()
                } else {
                    self.stop()
                    self.items = []
                    self.lastSignalAt = nil
                    self.limiter.reset()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 内部工具

    /// 把 store 的最新状态同步到 `@Published`。所有用户操作走完都要调它。
    /// 落盘由 store 的各个写入方法自己排，这里不重复触发。
    private func syncAndPersist() {
        items = store.items
    }

    /// 重启后恢复"上次信号"时刻：取已存条目里最晚的摄取时间。
    ///
    /// 全部条目都被清空过时无从恢复，健康度会退回"从未收到"。
    /// 这是有意的保守取值——宁可提示北城去检查投递方，也不要用一个编出来的时间伪装成正常。
    private func restoredLastSignal() -> Date? {
        store.items.map(\.receivedAt).max()
    }

    /// 按固定间隔通知界面重算健康度。只在监听期间运行。
    private func startHealthTicker() {
        healthTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthTickInterval))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    // 顺带收掉过期条目。被 kill -9 的会话不会发 Stop，
                    // 它那条 running 只能靠 ttl 到期在这里被清掉。
                    if self.store.pruneExpired() > 0 {
                        self.items = self.store.items
                        self.store.persist()
                    }
                    self.objectWillChange.send()
                }
            }
        }
    }

    /// 原子写一条投递文件：先写同目录下的临时文件，再 rename 过来。
    /// 同目录 rename 由内核保证原子性，watcher 永远读不到写了一半的内容。
    /// 这与 README 里要求外部投递方遵守的写法完全一致。
    private func writeDelivery(_ payload: [String: Any]) throws {
        InboxLocation.ensureSpoolExists()
        let directory = InboxLocation.spool
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let temporary = directory.appendingPathComponent(".tmp.\(UUID().uuidString)")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let final = directory.appendingPathComponent("\(stamp)-atoll-\(UUID().uuidString.prefix(8)).json")

        try data.write(to: temporary)
        do {
            try FileManager.default.moveItem(at: temporary, to: final)
        } catch {
            // rename 失败时临时文件会以点开头留在目录里，主动清掉，别给投递目录留垃圾
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
