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
// 待办页最容易出错的纯逻辑：标题清洗、截止日期换算（跨月跨年、时区、非公历系统日历）、
// 列表排序与截止标签，以及快捷键借焦点后收起时焦点还给谁。
// 它们只依赖 Foundation，命令行工具链即可编译运行，不需要 Xcode：
//
//     swiftc -o /tmp/todo_probe \
//       DynamicIsland/managers/Todo/TodoItem.swift \
//       DynamicIsland/managers/Todo/TodoFocusPolicy.swift \
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
        checkFocusReturn()

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

        // 系统日历是佛历时，EKReminder 收到非公历分量会抛异常让 App 崩溃，这里必须仍输出公历分量
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let fromBuddhist = TodoDueOption.today.dueDateComponents(now: lateNight, calendar: buddhist)
        check("佛历系统下仍输出公历日历", fromBuddhist?.calendar?.identifier == .gregorian)
        check("佛历系统下年份仍是公历年份", fromBuddhist?.year == 2026 && fromBuddhist?.day == 28)

        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = calendar.timeZone
        let fromJapanese = TodoDueOption.tomorrow.dueDateComponents(now: lateNight, calendar: japanese)
        check("日本历系统下仍输出公历分量", fromJapanese?.calendar?.identifier == .gregorian && fromJapanese?.year == 2026)

        let newYear = TodoDueOption.tomorrow.dueDateComponents(now: date(2026, 12, 31, 22), calendar: calendar)
        check("年末的明天跨到下一年", newYear?.year == 2027 && newYear?.month == 1 && newYear?.day == 1)

        // 「今天」按传入日历的时区算：同一时刻在上海已是 29 日，在洛杉矶还是 28 日
        let instant = date(2026, 9, 29, 4, 0)
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let shanghaiToday = TodoDueOption.today.dueDateComponents(now: instant, calendar: calendar)
        let losAngelesToday = TodoDueOption.today.dueDateComponents(now: instant, calendar: losAngeles)
        check("今天按传入日历的时区计算", shanghaiToday?.day == 29 && losAngelesToday?.day == 28)
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

    static func checkFocusReturn() {
        print("收起后焦点去向")
        func decide(
            active: Bool = true,
            otherKey: Bool = false,
            opened: Bool = false,
            previous: Bool = false,
            app: Bool = true
        ) -> TodoFocusReturn {
            TodoFocusPolicy.decide(
                atollIsActive: active,
                keyWindowIsOther: otherKey,
                openedWindowAvailable: opened,
                previousWindowAvailable: previous,
                returnAppAvailable: app
            )
        }
        check("常规：还给借焦点前的前台 App", decide() == .returnApp)
        check("用户已点到别的 App：不抢回", decide(active: false) == .keep)
        check("焦点已在 Atoll 设置等其他窗口：不动", decide(otherKey: true, previous: true) == .keep)
        check("借焦点期间开了设置又点回刘海：交给设置窗口", decide(opened: true, previous: true) == .openedWindow)
        check("借焦点前开着 Atoll 自己的窗口：还给那个窗口", decide(previous: true) == .previousWindow)
        check("借焦点时 Atoll 已在前台且无窗口可还：让出前台", decide(app: false) == .deactivate)
    }
}
