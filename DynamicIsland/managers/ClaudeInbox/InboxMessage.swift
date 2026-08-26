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
import SwiftUI

/// 消息状态。取值直接对应 Claude 在正文里自己声明的标记（`needs input:` / `result:` / `failed:`），
/// 由投递方判定后写入，Atoll 只呈现不推导。
///
/// `idle` 是诚实的兜底：Claude 停止输出但没有声明任何标记时用它，
/// 表示"停下了，但无从判断是完成还是在等人"。
enum InboxStatus: String, Codable, CaseIterable {
    case needsInput = "needs_input"
    case running
    case idle
    case done
    case failed
    case info
    /// 投递方主动撤回该 key 的条目（例如 SessionEnd），摄取时直接删除对应条目。
    case cleared

    /// 未知或缺失状态一律降级为 `info`，保证任何畸形消息仍能显示出来。
    /// 静默丢消息比显示一条模糊消息糟得多——这是本模块的总原则。
    init(lenient raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let parsed = InboxStatus(rawValue: raw) else {
            self = .info
            return
        }
        self = parsed
    }

    /// 是否属于"还没了结、需要北城处理"的状态。角标计数与横幅门禁都基于它。
    var isPending: Bool {
        switch self {
        case .needsInput, .idle: return true
        case .running, .done, .failed, .info, .cleared: return false
        }
    }

    /// 是否为终态。终态条目在自动清理时优先淘汰。
    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        case .needsInput, .running, .idle, .info, .cleared: return false
        }
    }

    /// 列表分桶排序权重，数字小的排前面：待确认 > 已停下 > 运行中 > 终态。
    var sortRank: Int {
        switch self {
        case .needsInput: return 0
        case .idle: return 1
        case .running: return 2
        case .failed: return 3
        case .done: return 4
        case .info: return 5
        case .cleared: return 6
        }
    }

    /// 状态点与色条的颜色。北城要的"黄色还是绿色"就落在这里。
    var tint: Color {
        switch self {
        case .needsInput: return .orange
        case .idle: return .yellow
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        case .info, .cleared: return .secondary
        }
    }

    /// 列表与角标上的中文短标签。
    var localizedLabel: String {
        switch self {
        case .needsInput: return String(localized: "Needs you")
        case .running: return String(localized: "Running")
        case .idle: return String(localized: "Stopped")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .info: return String(localized: "Info")
        case .cleared: return String(localized: "Cleared")
        }
    }

    /// 缺省 SF Symbol，投递方没给 icon 时用。
    var defaultIcon: String {
        switch self {
        case .needsInput: return "questionmark.bubble.fill"
        case .running: return "circle.dotted"
        case .idle: return "pause.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .info, .cleared: return "info.circle.fill"
        }
    }
}

/// 呈现等级。由投递方逐条指定，是"完全可控"落到单条消息粒度的抓手。
/// Atoll 侧的规则引擎只能在此基础上**降级**，不会升级——投递方说不要打扰就一定不打扰。
enum InboxPresentation: String, Codable, Comparable {
    /// 只进列表，不计入角标，不弹横幅。
    case silent
    /// 进列表并计入角标，不弹横幅。
    case badge
    /// 进列表、计入角标，并弹一次瞬时横幅。
    case sneak

    private var rank: Int {
        switch self {
        case .silent: return 0
        case .badge: return 1
        case .sneak: return 2
        }
    }

    static func < (lhs: InboxPresentation, rhs: InboxPresentation) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 缺失时按状态推定：需要确认的默认弹横幅，其余只更角标。
    static func `default`(for status: InboxStatus) -> InboxPresentation {
        status == .needsInput ? .sneak : .badge
    }

    /// 未知取值降级为 `badge`，避免投递方笔误导致意外打扰。
    init(lenient raw: String?, status: InboxStatus) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            self = .default(for: status)
            return
        }
        // 兼容布尔写法 sneak:true，早期 hook 脚本可能这么写
        if raw == "true" { self = .sneak; return }
        if raw == "false" { self = .badge; return }
        self = InboxPresentation(rawValue: raw) ?? .badge
    }
}

/// 优先级。仅影响排序与规则匹配，不单独决定是否打扰（那由 `presentation` 决定）。
enum InboxPriority: String, Codable {
    case low, normal, high

    init(lenient raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let parsed = InboxPriority(rawValue: raw) else {
            self = .normal
            return
        }
        self = parsed
    }

    var sortRank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }
}

/// 一条 inbox 消息。对应投递目录里的一个 JSON 文件。
///
/// 解码纪律：**任何字段缺失或类型不符都不得导致整条消息被拒**，一律回退到安全默认值。
/// 投递方是外部进程（hook 脚本、CI、随手写的 shell），把消息丢掉等于让北城错过提醒，
/// 而这个功能存在的全部意义就是不让他错过。
struct InboxMessage: Identifiable, Equatable {
    /// 支持的最高 schema 版本。收到更高版本时降级渲染并打标记，不拒绝。
    static let supportedVersion = 1

    /// 单条消息长度上限。超长的 detail 会被截断，避免一条消息撑爆列表或日志。
    static let maxDetailLength = 2000
    static let maxTitleLength = 200

    let id: String
    /// 折叠键。同一个 `source + key` 的后续消息覆盖前一条，
    /// 使一个 session 在列表里始终只占一行。
    let key: String
    let source: String
    var status: InboxStatus
    var title: String
    var detail: String?
    var cwd: String?
    var icon: String?
    var presentation: InboxPresentation
    var priority: InboxPriority
    var tags: [String]
    /// 投递方声明的时间。乱序到达时用它丢弃过期消息。
    var timestamp: Date
    /// 存活秒数，`nil` 表示不自动过期。
    var ttl: TimeInterval?
    /// 投递方声明的 schema 版本高于 `supportedVersion` 时为 true，UI 上给个"格式较新"标记。
    var isFutureVersion: Bool
    /// 北城是否已读。已读的条目不再计入角标。
    var isRead: Bool = false
    /// 本条被 Atoll 摄取的时间，用于"上次信号"健康指示。
    var receivedAt: Date = .now

    /// 折叠命名空间，`source` 与 `key` 组合后才是唯一身份——
    /// 不同来源可能各自用了同名的 key。
    var collapseKey: String { "\(source)\u{1F}\(key)" }

    /// 是否已超过 ttl。过期条目在自动清理时被淘汰。
    var isExpired: Bool {
        guard let ttl else { return false }
        return Date().timeIntervalSince(timestamp) > ttl
    }

    /// 有效图标：投递方指定优先，否则按状态取默认值。
    var resolvedIcon: String { icon?.isEmpty == false ? icon! : status.defaultIcon }

    static func == (lhs: InboxMessage, rhs: InboxMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.isRead == rhs.isRead
            && lhs.timestamp == rhs.timestamp
    }
}

extension InboxMessage {
    /// 从投递文件的 JSON 字典宽松解码。
    ///
    /// - Parameters:
    ///   - object: `JSONSerialization` 解出的顶层字典。
    ///   - fallbackID: 文件名派生的 id，JSON 里没给 `key` 时兼作折叠键。
    ///   - fileDate: 文件 mtime，JSON 里没给 `ts` 时用它。
    /// - Returns: 永远返回一条消息；顶层不是字典时返回 `nil`，由调用方移入 `rejected/`。
    init?(lenient object: Any, fallbackID: String, fileDate: Date) {
        guard let dict = object as? [String: Any] else { return nil }

        let version = Self.int(dict["v"]) ?? 1
        self.isFutureVersion = version > Self.supportedVersion

        self.status = InboxStatus(lenient: Self.string(dict["status"]))
        self.source = Self.string(dict["source"])?.nonEmpty ?? "unknown"
        self.key = Self.string(dict["key"])?.nonEmpty ?? fallbackID
        self.id = fallbackID

        // title 缺失时用状态标签合成，保证列表里永远有东西可显示
        let rawTitle = Self.string(dict["title"])?.nonEmpty
        self.title = String((rawTitle ?? status.localizedLabel).prefix(Self.maxTitleLength))

        self.detail = Self.string(dict["detail"])?.nonEmpty.map { String($0.prefix(Self.maxDetailLength)) }
        self.cwd = Self.string(dict["cwd"])?.nonEmpty
        self.icon = Self.string(dict["icon"])?.nonEmpty

        self.presentation = InboxPresentation(lenient: Self.presentationRaw(dict["present"]), status: status)
        self.priority = InboxPriority(lenient: Self.string(dict["priority"]))

        self.tags = (dict["tags"] as? [Any])?
            .compactMap { Self.string($0)?.nonEmpty }
            .prefix(8)
            .map { $0 } ?? []

        // ts 允许秒或毫秒；钳到 now+60s 以内，防止投递方时钟超前把条目永远顶在列表最上面
        if let ts = Self.double(dict["ts"]) {
            let seconds = ts > 1_000_000_000_000 ? ts / 1000 : ts
            self.timestamp = min(Date(timeIntervalSince1970: seconds), Date().addingTimeInterval(60))
        } else {
            self.timestamp = fileDate
        }

        if let ttl = Self.double(dict["ttl"]), ttl > 0 {
            self.ttl = ttl
        } else {
            self.ttl = nil
        }
    }

    /// `present` 既接受字符串枚举，也接受布尔（`"present": true` 等价于 `sneak`）。
    private static func presentationRaw(_ value: Any?) -> String? {
        if let b = value as? Bool { return b ? "true" : "false" }
        return string(value)
    }

    /// 宽松取字符串：数字、布尔也接受，转成字符串形式。
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

private extension String {
    /// 去掉首尾空白后为空则返回 nil，用于把空字符串和缺失统一成一种情况。
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
