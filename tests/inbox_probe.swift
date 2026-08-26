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

// Inbox 契约层行为探针。
//
// tests/ 下的 Python 测试只断言接入点的文本存在，管不到运行时行为。
// 这个探针把最容易出错的两块逻辑真跑一遍：投递文件的容错解码，与条目合并的状态机。
// 它只依赖 Foundation，因此不需要 Xcode，命令行工具链就能跑：
//
//     swiftc -o /tmp/inbox_probe \
//       DynamicIsland/managers/ClaudeInbox/InboxMessage.swift \
//       DynamicIsland/managers/ClaudeInbox/InboxLocation.swift \
//       DynamicIsland/managers/ClaudeInbox/InboxStore.swift \
//       tests/inbox_probe.swift && /tmp/inbox_probe
//
// 退出码非零表示有断言失败。

import Foundation

@main
struct InboxProbe {
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

    /// 用字典造一条消息，模拟投递方写出的 JSON。
    static func make(_ dict: [String: Any], id: String = UUID().uuidString, date: Date = Date()) -> InboxMessage? {
        InboxMessage(lenient: dict, fallbackID: id, fileDate: date)
    }

    static func main() {
        decoding()
        stateMachine()
        print("")
        print("checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 容错解码

    /// 投递方是外部进程，字段缺失与类型写错都很常见。
    /// 这一组断言守的是「任何畸形输入都不得让消息消失」这条总原则。
    static func decoding() {
        print("[1] 容错解码")

        check("完全空字典也能解出消息", make([:]) != nil)
        check("空字典降级为 info", make([:])?.status == .info)
        check("空字典的 title 用状态标签兜底", make([:])?.title.isEmpty == false)
        check("未知 status 降级为 info", make(["status": "bogus_state"])?.status == .info)
        check("status 大小写与空白不敏感", make(["status": "  NEEDS_INPUT "])?.status == .needsInput)
        check("顶层不是字典时返回 nil",
              InboxMessage(lenient: ["a", "b"], fallbackID: "x", fileDate: Date()) == nil)

        check("数字型 title 被转成字符串", make(["title": 12345])?.title == "12345")
        check("空字符串 title 回退到状态标签",
              make(["status": "done", "title": "   "])?.title == InboxStatus.done.localizedLabel)

        check("毫秒时间戳被识别", {
            guard let m = make(["ts": 1_787_713_844_000.0]) else { return false }
            return abs(m.timestamp.timeIntervalSince1970 - 1_787_713_844) < 1
        }())
        check("秒时间戳被识别", {
            guard let m = make(["ts": 1_787_713_844]) else { return false }
            return abs(m.timestamp.timeIntervalSince1970 - 1_787_713_844) < 1
        }())
        check("超前时钟被钳制在 now+60s 内", {
            let far = Date().addingTimeInterval(86_400).timeIntervalSince1970
            guard let m = make(["ts": far]) else { return false }
            return m.timestamp <= Date().addingTimeInterval(61)
        }())
        check("缺 ts 时用文件时间", {
            let d = Date(timeIntervalSince1970: 1_700_000_000)
            return make([:], date: d)?.timestamp == d
        }())

        check("present 布尔 true 等价于 sneak", make(["present": true])?.presentation == .sneak)
        check("present 未知值降级为 badge", make(["present": "explode"])?.presentation == .badge)
        check("needs_input 缺 present 时默认弹横幅", make(["status": "needs_input"])?.presentation == .sneak)
        check("done 缺 present 时只更角标", make(["status": "done"])?.presentation == .badge)

        check("tags 上限 8 条", {
            let many = (0..<20).map { "t\($0)" }
            return make(["tags": many])?.tags.count == 8
        }())
        check("tags 里的非字符串被跳过", make(["tags": ["a", 1, NSNull(), "b"]])?.tags == ["a", "1", "b"])

        check("更高版本被标记", make(["v": 99])?.isFutureVersion == true)
        check("当前版本不被标记", make(["v": 1])?.isFutureVersion == false)

        check("超长 detail 被截断", {
            let long = String(repeating: "x", count: 9999)
            return (make(["detail": long])?.detail?.count ?? 0) <= InboxMessage.maxDetailLength
        }())

        check("缺省 source 为 unknown", make([:])?.source == "unknown")
        check("collapseKey 由 source 与 key 组合", {
            guard let a = make(["source": "s", "key": "k"]),
                  let b = make(["source": "s2", "key": "k"]) else { return false }
            return a.collapseKey != b.collapseKey
        }())
    }

    // MARK: - store 状态机

    /// 合并、去重、乱序保护、已读迁移、容量淘汰。
    /// 这几条错了的表现都是「角标数字不对」或「横幅该弹不弹」，肉眼很难归因，所以必须自动化守住。
    static func stateMachine() {
        print("[2] store 状态机")

        MainActor.assumeIsolated {
            func msg(_ status: String, key: String = "sess1", ts: Double, id: String = UUID().uuidString) -> InboxMessage {
                make(["status": status, "key": key, "source": "claude-code", "ts": ts, "title": "t-\(status)"], id: id)!
            }

            let base = Date().timeIntervalSince1970

            let s1 = InboxStore()
            _ = s1.ingest([msg("running", ts: base)])
            _ = s1.ingest([msg("running", ts: base + 1)])
            check("同 key 折叠成一条", s1.items.count == 1)

            let s2 = InboxStore()
            _ = s2.ingest([msg("running", ts: base)])
            check("同状态重推不返回迁移（不会触发横幅）", s2.ingest([msg("running", ts: base + 1)]).isEmpty)

            let s3 = InboxStore()
            _ = s3.ingest([msg("running", ts: base)])
            check("running→needs_input 返回迁移（会触发横幅）",
                  s3.ingest([msg("needs_input", ts: base + 1)]).count == 1)

            // 已读态的三条规则：同一条重投保留、状态迁移清零、同会话的新问题也清零。
            // 第三条是实际使用中最容易漏的：Claude 连着问第二个问题时状态没变，
            // 若不当作新事件，行内容会被悄悄换掉而人毫不知情。
            let s4 = InboxStore()
            let sameID = "delivery-fixed-id"
            _ = s4.ingest([msg("needs_input", ts: base, id: sameID)])
            s4.markRead(id: s4.items[0].id)
            check("markRead 生效", s4.items[0].isRead == true)
            _ = s4.ingest([msg("needs_input", ts: base + 1, id: sameID)])
            check("同一条重投保留已读", s4.items[0].isRead == true)
            check("同会话的新问题清零已读",
                  s4.ingest([msg("needs_input", ts: base + 2, id: "delivery-other-id")]).count == 1)
            check("新问题后回到未读", s4.items[0].isRead == false)
            _ = s4.ingest([msg("running", ts: base + 3)])
            check("状态迁移清零已读", s4.items[0].isRead == false)

            let s5 = InboxStore()
            _ = s5.ingest([msg("needs_input", ts: base + 100)])
            _ = s5.ingest([msg("done", ts: base + 1)])
            check("晚到的旧消息不覆盖新状态", s5.items[0].status == .needsInput)

            let s6 = InboxStore()
            _ = s6.ingest([msg("needs_input", ts: base)])
            _ = s6.ingest([msg("cleared", ts: base + 1)])
            check("cleared 删掉条目", s6.items.isEmpty)

            let s7 = InboxStore()
            _ = s7.ingest([
                msg("needs_input", key: "a", ts: base),
                msg("running", key: "b", ts: base),
                msg("done", key: "c", ts: base),
                msg("idle", key: "d", ts: base),
            ])
            check("pendingCount 含 needs_input 与 idle", s7.pendingCount == 2)
            check("runningCount 只数 running", s7.runningCount == 1)
            s7.markAllRead()
            check("全部已读后 pendingCount 归零", s7.pendingCount == 0)

            let s8 = InboxStore()
            _ = s8.ingest([
                msg("done", key: "a", ts: base),
                msg("needs_input", key: "b", ts: base),
                msg("running", key: "c", ts: base),
            ])
            check("待确认排在最前", s8.items.first?.status == .needsInput)
            check("终态排在最后", s8.items.last?.status == .done)

            // 容量淘汰的红线：终态可以被挤掉，仍在等人的条目不能。
            let s9 = InboxStore()
            _ = s9.ingest([msg("needs_input", key: "keepme", ts: base)])
            var flood: [InboxMessage] = []
            for i in 0..<400 {
                flood.append(msg("done", key: "flood\(i)", ts: base + Double(i) + 10))
            }
            _ = s9.ingest(flood)
            check("淘汰后总量受限", s9.items.count <= 200)
            check("活着的 needs_input 没被挤掉", s9.items.contains { $0.key == "keepme" })

            let s10 = InboxStore()
            _ = s10.ingest([msg("needs_input", key: "x", ts: base)])
            s10.remove(id: s10.items[0].id)
            check("remove 删掉单条", s10.items.isEmpty)

            // 同一时刻到达的一批：紧急的必须赢。投递方按秒精度写时间戳时这是常态，
            // 而目录枚举顺序未定义，没有确定性次键的话结果是随机的。
            let s11 = InboxStore()
            _ = s11.ingest([
                make(["status": "needs_input", "key": "same", "source": "x", "ts": base, "title": "问"], id: "i1")!,
                make(["status": "running", "key": "same", "source": "x", "ts": base, "title": "跑"], id: "i2")!,
            ])
            check("同一时刻 needs_input 赢过 running", s11.items[0].status == .needsInput)

            // ttl 到期的条目由定期清理收掉。容量没超时也必须生效，
            // 否则被 kill 掉的会话会把角标永久钉在运行中。
            let s12 = InboxStore()
            _ = s12.ingest([
                make(["status": "running", "key": "dead", "source": "x", "ts": base - 100, "ttl": 1])!,
                make(["status": "running", "key": "alive", "source": "x", "ts": base, "ttl": 86400])!,
            ])
            check("清理前两条都在", s12.items.count == 2)
            check("pruneExpired 清掉一条", s12.pruneExpired() == 1)
            check("过期的被清掉、没过期的留下", s12.items.count == 1 && s12.items[0].key == "alive")
            check("过期条目不计入 runningCount", s12.runningCount == 1)
        }
    }
}
