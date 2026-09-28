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

/// 刘海待办页的一条待办。
///
/// 数据源是「提醒事项」里的 EKReminder，这里只保留待办页用得到的字段。
/// 本文件只依赖 Foundation，纯逻辑可以用 tests/todo_probe.swift 在命令行下单独验证。
struct TodoItem: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    /// 截止时间；nil 表示没有设截止。
    var dueDate: Date?
    /// 截止只精确到天（全天待办），标签里不显示具体时刻。
    var isAllDay: Bool
    var isCompleted: Bool
    var creationDate: Date?
}

/// 新建待办时可选的截止日期。
enum TodoDueOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case today
    case tomorrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No date"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        }
    }

    /// 返回全天截止的年月日分量；`.none` 返回 nil。
    ///
    /// 只给年月日、不给时分，「提醒事项」会把它当成当天的全天待办，在当天显示。
    /// 不带时区（浮动日期），与「提醒事项」自己创建的全天待办一致：换时区后仍落在同一天。
    ///
    /// 分量一律按公历生成：EKReminder.dueDateComponents 只接受公历，传入佛历、日本历等会直接抛
    /// NSInvalidArgumentException 让 App 崩溃。传入的 `calendar` 只用来确定「今天」按哪个时区算。
    func dueDateComponents(now: Date, calendar: Calendar) -> DateComponents? {
        let dayOffset: Int
        switch self {
        case .none: return nil
        case .today: dayOffset = 0
        case .tomorrow: dayOffset = 1
        }
        let gregorian = TodoLogic.gregorianCalendar(timeZone: calendar.timeZone)
        let startOfToday = gregorian.startOfDay(for: now)
        guard let target = gregorian.date(byAdding: .day, value: dayOffset, to: startOfToday) else { return nil }
        var components = gregorian.dateComponents([.year, .month, .day], from: target)
        components.calendar = gregorian
        return components
    }
}

/// 截止标签：显示文字与是否已过期（过期用醒目色）。
struct TodoDueLabel: Equatable, Sendable {
    let text: String
    let isOverdue: Bool
}

/// 待办页的纯逻辑，与 EventKit、界面都无关。
enum TodoLogic {
    /// 指定时区的公历。与「提醒事项」交换日期分量时一律用它，系统日历设成佛历等也不受影响。
    static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 清洗用户输入的标题：换行折叠成空格，去掉首尾空白；清洗后为空返回 nil，调用方据此拒绝添加。
    static func normalizedTitle(_ raw: String) -> String? {
        let singleLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 列表排序：有截止的排前面、按截止先后；没有截止的排后面、新建的在上。
    /// 同一位置再按标题排，保证每次刷新顺序稳定、列表不会跳动。
    static func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?):
                return left == right ? lhs.title < rhs.title : left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                switch (lhs.creationDate, rhs.creationDate) {
                case let (left?, right?):
                    return left == right ? lhs.title < rhs.title : left > right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.title < rhs.title
                }
            }
        }
    }

    /// 截止标签；没有截止返回 nil。
    ///
    /// 全天待办按「天」比较：截止日在今天之前才算过期，当天全天待办整天都不算过期。
    /// 带时刻的待办按时刻比较：当天已过的时刻即算过期。
    static func dueLabel(for item: TodoItem, now: Date, calendar: Calendar) -> TodoDueLabel? {
        guard let due = item.dueDate else { return nil }

        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: due)
        let dayDelta = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        let isOverdue = item.isAllDay ? dayDelta < 0 : due < now

        if isOverdue {
            return TodoDueLabel(text: "Overdue", isOverdue: true)
        }

        let time = item.isAllDay ? nil : timeText(due, calendar: calendar)
        switch dayDelta {
        case 0:
            return TodoDueLabel(text: time.map { "Today \($0)" } ?? "Today", isOverdue: false)
        case 1:
            return TodoDueLabel(text: time.map { "Tomorrow \($0)" } ?? "Tomorrow", isOverdue: false)
        default:
            return TodoDueLabel(text: dayText(due, calendar: calendar), isOverdue: false)
        }
    }

    private static func timeText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
