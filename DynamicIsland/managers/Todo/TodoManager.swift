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
import EventKit
import Foundation

/// 「提醒事项」里一个可写入的列表，供设置页选择待办存放位置。
struct TodoReminderList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// 所属账户（iCloud、本地等），同名列表靠它区分。
    let accountTitle: String
}

/// 刘海待办页的数据层：读写「提醒事项」。
///
/// 待办页展示一个列表里全部未完成的提醒（含没设截止的），新建待办也写进这个列表，
/// 因此会同步到 iPhone 等其他设备。
///
/// 列表 ID 由界面层从 Defaults 传入（`activate(listID:)` / `updateListID(_:)`），
/// 本类不直接读 Defaults：空字符串表示使用系统默认的提醒列表。
@MainActor
final class TodoManager: ObservableObject {
    static let shared = TodoManager()

    enum AccessState: Equatable {
        case notDetermined
        case granted
        case denied
    }

    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var lists: [TodoReminderList] = []
    @Published private(set) var accessState: AccessState
    /// 当前展示与写入的列表名；解析不到任何可写列表时为 nil。
    @Published private(set) var activeListTitle: String?
    /// 最近一次读写失败的提示；下一次成功的读写会清空它。
    @Published private(set) var lastError: String?
    /// 刚勾选完成、正在淡出的条目。淡出结束才从列表移除，勾选后能看到一下反馈。
    @Published private(set) var completingIDs: Set<String> = []
    /// 输入框聚焦请求计数。快捷键打开待办页时递增，待办页监听到变化后把键盘焦点给输入框。
    @Published private(set) var inputFocusRequest = 0
    /// 还没提交的输入与截止选项。放在这里而不是待办页视图里，刘海收起（视图销毁）后再打开草稿还在。
    @Published var draftTitle = ""
    @Published var draftDue: TodoDueOption = .none

    private let store = EKEventStore()
    private var listID = ""
    private var storeObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var hasPendingFocusRequest = false
    /// 每次发起读取递增，读取返回时据此判断自己是否已被更新的读取取代。
    private var refreshGeneration = 0

    /// 勾选完成后保留在列表里的时长。
    private let completionLinger: Duration = .milliseconds(700)

    private init() {
        accessState = Self.currentAccessState()
    }

    /// 待办页出现时调用：权限未决定就申请，开始监听「提醒事项」变化，并刷新列表。
    func activate(listID: String) async {
        self.listID = listID
        startObservingStore()
        if accessState == .notDetermined {
            await requestAccess()
        } else {
            accessState = Self.currentAccessState()
        }
        await refresh()
    }

    /// 请求待办页把键盘焦点给输入框，供快捷键「打开即输入」使用。
    ///
    /// 快捷键切到待办页时视图是新建的，请求可能早于视图出现，
    /// 所以除了递增计数通知已显示的视图，还要留一个待处理标记给视图出现时取走。
    func requestInputFocus() {
        hasPendingFocusRequest = true
        inputFocusRequest &+= 1
    }

    /// 取走一次待处理的聚焦请求；没有请求时返回 false。
    func consumeInputFocusRequest() -> Bool {
        defer { hasPendingFocusRequest = false }
        return hasPendingFocusRequest
    }

    /// 设置页切换目标列表后调用。
    func updateListID(_ listID: String) async {
        guard listID != self.listID else { return }
        self.listID = listID
        await refresh()
    }

    /// 申请「提醒事项」完整访问权限。已拒绝时系统不会再弹窗，需要用户去系统设置里打开。
    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            lastError = "Reminders access request failed: \(error.localizedDescription)"
        }
        accessState = Self.currentAccessState()
    }

    /// 重新读取列表与未完成待办。没有权限时清空展示，避免显示过期数据。
    func refresh() async {
        await refresh(finishing: nil)
    }

    /// 重新读取；`finishedID` 是刚淡出完的已完成条目，在拿到新数据的同一轮里才解除它的完成态，
    /// 避免读取期间那一行先闪回未勾选、勾选框又能点。
    private func refresh(finishing finishedID: String?) async {
        // 读取可能乱序返回：只采用最后发起的那次，较早发起、较晚返回的快照可能早于刚做的保存
        refreshGeneration &+= 1
        let generation = refreshGeneration
        accessState = Self.currentAccessState()
        guard accessState == .granted else {
            if let finishedID { completingIDs.remove(finishedID) }
            items = []
            lists = []
            activeListTitle = nil
            return
        }

        lists = store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { TodoReminderList(id: $0.calendarIdentifier, title: $0.title, accountTitle: $0.source.title) }
            .sorted { ($0.accountTitle, $0.title) < ($1.accountTitle, $1.title) }

        guard let calendar = resolveTargetCalendar() else {
            if let finishedID { completingIDs.remove(finishedID) }
            items = []
            activeListTitle = nil
            lastError = "No writable Reminders list found."
            return
        }
        activeListTitle = calendar.title

        let fetched = await Self.fetchIncomplete(from: store, in: calendar)
        if let finishedID { completingIDs.remove(finishedID) }
        guard generation == refreshGeneration else {
            // 更新的读取仍在途，列表由它决定；已完成的条目先移出，淡出结束后不会闪回未勾选
            if let finishedID { items.removeAll { $0.id == finishedID } }
            return
        }
        // 仍在淡出的条目保留旧行；重复提醒完成后以同一 ID 滚到下一次，淡出结束才换成新数据
        items = TodoLogic.sorted(fetched.filter { !completingIDs.contains($0.id) } + items.filter { completingIDs.contains($0.id) })
        lastError = nil
    }

    /// 新建一条待办；标题清洗后为空、没有权限或写入失败时返回 false。
    @discardableResult
    func add(title rawTitle: String, due: TodoDueOption) async -> Bool {
        guard let title = TodoLogic.normalizedTitle(rawTitle) else { return false }
        guard accessState == .granted, let calendar = resolveTargetCalendar() else {
            lastError = "Grant Reminders access to add todos."
            return false
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        reminder.dueDateComponents = due.dueDateComponents(now: Date(), calendar: .current)

        do {
            try store.save(reminder, commit: true)
        } catch {
            lastError = "Could not save todo: \(error.localizedDescription)"
            return false
        }

        // 先把新条目放进列表，界面立即有反馈；随后的「提醒事项」变更通知会再做一次完整刷新
        items = TodoLogic.sorted(items + [TodoItem(reminder: reminder)])
        lastError = nil
        return true
    }

    /// 勾选完成：写回「提醒事项」，短暂保留在列表里再重新读取。写入失败时把提醒恢复为未完成。
    ///
    /// 淡出结束后重新读取而不是直接从列表删掉：重复提醒完成后会以同一个 ID 滚到下一次，
    /// 重新读取才能让下一次的待办留在列表里。
    func complete(_ item: TodoItem) async {
        // 淡出期间勾选框已禁用，但读屏的「标记完成」操作不受禁用约束；重复提醒被再次完成会跳过一次
        guard !completingIDs.contains(item.id) else { return }
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            await refresh()
            return
        }

        completingIDs.insert(item.id)
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            reminder.isCompleted = false
            completingIDs.remove(item.id)
            lastError = "Could not complete todo: \(error.localizedDescription)"
            return
        }

        try? await Task.sleep(for: completionLinger)
        await refresh(finishing: item.id)
    }

    /// 删除一条待办（从「提醒事项」里移除），由用户在待办页右键菜单主动触发。
    func delete(_ item: TodoItem) async {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            await refresh()
            return
        }
        do {
            try store.remove(reminder, commit: true)
            items.removeAll { $0.id == item.id }
            lastError = nil
        } catch {
            lastError = "Could not delete todo: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private static func currentAccessState() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    /// 选中的列表不存在（被删、换了账户）或不可写时，回落到系统默认的提醒列表。
    private func resolveTargetCalendar() -> EKCalendar? {
        if !listID.isEmpty,
           let chosen = store.calendar(withIdentifier: listID),
           chosen.allowsContentModifications {
            return chosen
        }
        return store.defaultCalendarForNewReminders()
    }

    /// 「提醒事项」在本机、iCloud 同步或其他 App 修改后都会发变更通知。
    /// 一次同步常连发多条通知，这里合并成一次刷新。
    private func startObservingStore() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// EventKit 在后台队列回调结果；回调里只把 EKReminder 转成值类型，不碰主线程状态。
    nonisolated private static func fetchIncomplete(from store: EKEventStore, in calendar: EKCalendar) async -> [TodoItem] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: [calendar]
            )
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(TodoItem.init(reminder:)))
            }
        }
    }
}

extension TodoItem {
    /// 从 EKReminder 取待办页需要的字段；没有时分的截止视为全天待办。
    ///
    /// EventKit 的日期分量是公历；分量没带日历时也按公历解读，系统日历是佛历等时年份才不会错位。
    init(reminder: EKReminder) {
        let components = reminder.dueDateComponents
        let fallback = TodoLogic.gregorianCalendar(timeZone: components?.timeZone ?? .current)
        let dueDate = components.flatMap { ($0.calendar ?? fallback).date(from: $0) }
        self.init(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            dueDate: dueDate,
            isAllDay: components?.hour == nil,
            isCompleted: reminder.isCompleted,
            creationDate: reminder.creationDate
        )
    }
}
