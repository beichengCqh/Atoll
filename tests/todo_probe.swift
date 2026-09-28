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

// Todo 纯逻辑行为探针。
//
// 待办页最容易出错的是三块纯逻辑：标题清洗、截止日期换算（跨月、跨时区）、列表排序与截止标签。
// 它们只依赖 Foundation，命令行工具链即可编译运行，不需要 Xcode：
//
//     swiftc -o /tmp/todo_probe \
//       DynamicIsland/managers/Todo/TodoItem.swift \
//       tests/todo_probe.swift && /tmp/todo_probe
//
// 退出码非零表示有断言失败。

import Foundation

@main
struct TodoProbe {
    static var failures = 0
    static var checks = 0

    static func check(_ label: String, _ condition: Bool) {
        checks += 1
        if condition {
            print("  ok    \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label)")
        }
    }

    /// 固定用上海时区的公历，断言不受运行机器时区影响。
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func item(
        _ id: String,
        due: Date? = nil,
        allDay: Bool = true,
        created: Date? = nil
    ) -> TodoItem {
        TodoItem(id: id, title: id, dueDate: due, isAllDay: allDay, isCompleted: false, creationDate: created)
    }

    static func main() {
        checkTitleNormalization()
        checkDueOptions()
        checkOrdering()
        checkDueLabels()

        print("\nchecks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func checkTitleNormalization() {
        print("标题清洗")
        check("去掉首尾空白与换行", TodoLogic.normalizedTitle("  买牛奶 \n") == "买牛奶")
        check("中间换行折叠成空格", TodoLogic.normalizedTitle("写周报\n发给组长") == "写周报 发给组长")
        check("全空白视为空标题", TodoLogic.normalizedTitle(" \n\t ") == nil)
        check("空字符串视为空标题", TodoLogic.normalizedTitle("") == nil)
    }

    static func checkDueOptions() {
        print("截止日期换算")
        let lateNight = date(2026, 9, 28, 23, 30)
        let today = TodoDueOption.today.dueDateComponents(now: lateNight, calendar: calendar)
        check("今天 = 当天年月日", today?.year == 2026 && today?.month == 9 && today?.day == 28)
        check("全天截止不带时分", today?.hour == nil && today?.minute == nil)
        check("全天截止是浮动日期（不带时区）", today?.timeZone == nil)

        let tomorrow = TodoDueOption.tomorrow.dueDateComponents(now: lateNight, calendar: calendar)
        check("深夜选明天仍是下一天", tomorrow?.day == 29 && tomorrow?.month == 9)

        let monthEnd = TodoDueOption.tomorrow.dueDateComponents(now: date(2026, 9, 30, 10), calendar: calendar)
        check("月末的明天跨到下个月", monthEnd?.year == 2026 && monthEnd?.month == 10 && monthEnd?.day == 1)

        check("无截止返回 nil", TodoDueOption.none.dueDateComponents(now: lateNight, calendar: calendar) == nil)
    }

    static func checkOrdering() {
        print("列表排序")
        let items = [
            item("undated-old", created: date(2026, 9, 1)),
            item("due-later", due: date(2026, 10, 3)),
            item("undated-new", created: date(2026, 9, 20)),
            item("due-sooner", due: date(2026, 9, 29)),
            item("undated-nocreation"),
        ]
        let order = TodoLogic.sorted(items).map(\.id)
        check("有截止的排前面且按先后", Array(order.prefix(2)) == ["due-sooner", "due-later"])
        check("无截止的新建在上", Array(order.suffix(3)) == ["undated-new", "undated-old", "undated-nocreation"])
    }

    static func checkDueLabels() {
        print("截止标签")
        let now = date(2026, 9, 28, 14, 0)
        func label(_ item: TodoItem) -> TodoDueLabel? {
            TodoLogic.dueLabel(for: item, now: now, calendar: calendar)
        }

        check("无截止没有标签", label(item("none")) == nil)

        let yesterday = label(item("y", due: date(2026, 9, 27)))
        check("昨天的全天截止算过期", yesterday?.isOverdue == true && yesterday?.text == "Overdue")

        let today = label(item("t", due: date(2026, 9, 28)))
        check("今天的全天截止不算过期", today?.isOverdue == false && today?.text == "Today")

        let tomorrow = label(item("m", due: date(2026, 9, 29)))
        check("明天显示 Tomorrow", tomorrow?.text == "Tomorrow" && tomorrow?.isOverdue == false)

        let pastTime = label(item("p", due: date(2026, 9, 28, 9, 0), allDay: false))
        check("今天已过的时刻算过期", pastTime?.isOverdue == true)

        let laterTime = label(item("l", due: date(2026, 9, 28, 18, 0), allDay: false))
        check("今天稍后的时刻以 Today 开头", laterTime?.isOverdue == false && laterTime?.text.hasPrefix("Today") == true)

        let farAway = label(item("f", due: date(2026, 10, 15)))
        check("远期截止显示具体日期", farAway?.isOverdue == false
            && farAway.map { !$0.text.isEmpty && $0.text != "Today" && $0.text != "Tomorrow" } == true)
    }
}
