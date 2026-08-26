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

import SwiftUI
import Defaults

/// 灵动岛展开后的 inbox 整页列表。
///
/// 本视图只读 `ClaudeInboxManager` 的现成属性：不解析、不落盘、不排序。
/// `manager.items` 已经按状态与时间排好序，按数组顺序直接渲染即可。
struct NotchInboxView: View {
    @ObservedObject private var manager = ClaudeInboxManager.shared
    /// 静音只抑制瞬时横幅，消息照常摄取、角标照常更新。
    @Default(.inboxMutedUntil) private var mutedUntil

    /// 静音按钮单次静音的时长。
    private static let muteDuration: TimeInterval = 3600

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if manager.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        // 刘海内固定深色，跟随系统浅色主题会让文字与卡片背景一起变白看不见
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            healthLabel
            Spacer(minLength: 8)
            if hasUnread {
                Button("Mark all read") { manager.markAllRead() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            muteButton
        }
        .frame(height: 18)
    }

    /// 推送链路健康指示。
    ///
    /// 空列表既可能是"没有待办"，也可能是"hook 没装上、消息根本没进来"，
    /// 这一行是唯一能区分两者的信息，不能省。
    @ViewBuilder
    private var healthLabel: some View {
        switch manager.signalHealth {
        case .healthy:
            Text("Last signal \(InboxRelativeTime.text(for: manager.lastSignalAt ?? .now))")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case .neverReceived:
            Text("No delivery received yet — check that the hook is installed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.orange).lineLimit(1).truncationMode(.tail)
        case .stale(let date):
            Text("No signal for \(InboxRelativeTime.duration(since: date))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.orange).lineLimit(1)
        }
    }

    private var muteButton: some View {
        Button {
            mutedUntil = isMuted ? .distantPast : Date().addingTimeInterval(Self.muteDuration)
        } label: {
            Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                .font(.system(size: 11)).foregroundStyle(isMuted ? Color.orange : Color.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Muted — click to unmute" : "Mute for 1 hour")
    }

    // MARK: - 列表与空态

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(manager.items) { message in
                    InboxRow(
                        message: message,
                        onTap: { manager.markRead(id: message.id) },
                        onDelete: { manager.remove(id: message.id) }
                    )
                }
            }
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    /// 空态分两种：从没收到过投递要给出配置引导，收到过则只是当前没有待办。
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: manager.lastSignalAt == nil ? "tray" : "checkmark.circle")
                .font(.system(size: 20)).foregroundStyle(.secondary)
            if manager.lastSignalAt == nil {
                Text("No delivery received yet").font(.system(size: 12, weight: .semibold))
                Text("Write a JSON file into this folder to push a message")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                // 纯路径拼接，不触碰磁盘；允许选中方便直接复制到 hook 脚本里
                Text(InboxLocation.spool.path)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .padding(.horizontal, 10)
            } else {
                Text("Nothing needs you").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 派生状态

    private var isMuted: Bool { mutedUntil > .now }

    /// 有未读条目时才显示"全部已读"按钮。
    private var hasUnread: Bool { manager.items.contains { !$0.isRead } }
}

// MARK: - 单条消息卡片

/// inbox 列表里的一行。点击标记已读，左划或点右侧小叉删除。
private struct InboxRow: View {
    let message: InboxMessage
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHovered = false

    /// 左划超过这个距离松手即删除，短距离回弹。
    private static let deleteThreshold: CGFloat = 60

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(message.status.tint).frame(width: 4)
            Image(systemName: message.resolvedIcon)
                .font(.system(size: 13)).foregroundStyle(message.status.tint).frame(width: 18)
            textColumn
            Spacer(minLength: 4)
            trailingColumn
            deleteButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 42)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        // 已读整体降透明度，未读靠标题字重区分
        .opacity(message.isRead ? 0.55 : 1)
        .offset(x: dragOffset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
        .gesture(swipeToDelete)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.status.localizedLabel): \(message.title)")
        .accessibilityAction(named: Text("Delete"), onDelete)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(message.title)
                    .font(.system(size: 12, weight: message.isRead ? .regular : .semibold))
                    .lineLimit(1).truncationMode(.tail)
                // schema 版本比本机支持的高：字段可能没渲染全，给个明示
                if message.isFutureVersion { tagLabel("Newer format") }
                // 非 Claude 的投递方要能一眼认出来
                if message.source != "claude-code" { tagLabel(message.source) }
            }
            if let detail = message.detail {
                Text(detail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(InboxRelativeTime.text(for: message.timestamp))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(message.status.localizedLabel)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(message.status.tint)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 悬停时才实体化的删除按钮。始终占位，避免出现时把整行挤动。
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .help("Delete this message")
    }

    private var swipeToDelete: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 只跟随左划，右划不产生位移
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                if -value.translation.width > Self.deleteThreshold {
                    onDelete()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
    }

    private func tagLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - 时间格式化

/// 相对时间与时长的格式化。
///
/// 两个 formatter 构造开销都不小，缓存成静态实例，不在 `body` 里新建。
private enum InboxRelativeTime {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// 时长只保留最大的一个单位，"6 小时"比"6 小时 12 分钟"在窄栏里更好读。
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short
        return formatter
    }()

    /// 形如"3 分钟前"。
    static func text(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    /// 从 `date` 到现在经过的时长，形如"6 小时"。
    static func duration(since date: Date) -> String {
        durationFormatter.string(from: Date().timeIntervalSince(date)) ?? ""
    }
}
