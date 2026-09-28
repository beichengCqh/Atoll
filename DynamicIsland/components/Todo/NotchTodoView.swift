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

import AppKit
import Defaults
import SwiftUI

/// 灵动岛展开后的待办页：顶部输入框随手记，下方是「提醒事项」里一个列表的未完成待办。
///
/// 读写都经 `TodoManager`，本视图只管输入与展示；排序由 manager 负责，按数组顺序渲染即可。
struct NotchTodoView: View {
    @ObservedObject private var manager = TodoManager.shared
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @Default(.todoReminderListID) private var listID

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            inputRow
            content
            if let error = manager.lastError {
                Text(error)
                    .font(.system(size: 10)).foregroundStyle(Color.orange)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        // 刘海内固定深色，跟随系统浅色主题会让文字与卡片背景一起变白看不见
        .environment(\.colorScheme, .dark)
        .task { await manager.activate(listID: listID) }
        .onAppear {
            if manager.consumeInputFocusRequest() { focusInput() }
        }
        .onChange(of: listID) { _, newValue in
            Task { await manager.updateListID(newValue) }
        }
        .onChange(of: manager.inputFocusRequest) { _, _ in
            if manager.consumeInputFocusRequest() { focusInput() }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(manager.activeListTitle ?? "Reminders")
                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if manager.accessState == .granted {
                Text("\(openCount) open")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 18)
    }

    // MARK: - 输入行

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField("Add a todo…", text: $manager.draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isInputFocused)
                .onSubmit(addDraft)
                // Esc 收起刘海；焦点归还由刘海收起时的 TodoKeyboardFocus.end(viewModel:) 统一处理
                .onExitCommand {
                    TodoKeyboardFocus.markKeyboardClose(of: vm)
                    vm.close()
                }
                .disabled(manager.accessState != .granted)
            dueChip
            Button(action: addDraft) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .help("Add todo (Return)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 截止日期开关：单击在 无 → 今天 → 明天 之间循环，比下拉菜单少一次点击。
    private var dueChip: some View {
        Button {
            let options = TodoDueOption.allCases
            let next = (options.firstIndex(of: manager.draftDue) ?? 0) + 1
            manager.draftDue = options[next % options.count]
        } label: {
            Label(manager.draftDue.label, systemImage: "calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(manager.draftDue == .none ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.white.opacity(manager.draftDue == .none ? 0.05 : 0.12), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Due date: click to cycle No date / Today / Tomorrow")
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch manager.accessState {
        case .notDetermined:
            accessPrompt(
                message: "Todos are saved to Apple Reminders.",
                buttonTitle: "Allow Reminders Access"
            ) {
                Task { await manager.requestAccess(); await manager.refresh() }
            }
        case .denied:
            accessPrompt(
                message: "Reminders access is off for Atoll.",
                buttonTitle: "Open System Settings"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .granted:
            if manager.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(manager.items) { item in
                    TodoRow(
                        item: item,
                        isCompleting: manager.completingIDs.contains(item.id),
                        onComplete: { Task { await manager.complete(item) } },
                        onDelete: { Task { await manager.delete(item) } }
                    )
                }
            }
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20)).foregroundStyle(.secondary)
            Text("All done").font(.system(size: 12, weight: .semibold))
            Text("Type above and press Return to add a todo")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessPrompt(message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 20)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private var openCount: Int {
        manager.items.filter { !manager.completingIDs.contains($0.id) }.count
    }

    private var canAdd: Bool {
        manager.accessState == .granted && TodoLogic.normalizedTitle(manager.draftTitle) != nil
    }

    /// 添加成功才清空输入并把截止重置为无；失败保留原文，错误提示由 manager 给出。
    /// 保存期间用户若又改了输入框，保留新输入，只在内容仍是刚提交的那句时才清空。
    private func addDraft() {
        guard canAdd else { return }
        let title = manager.draftTitle
        let chosenDue = manager.draftDue
        Task {
            if await manager.add(title: title, due: chosenDue) {
                if manager.draftTitle == title {
                    manager.draftTitle = ""
                    manager.draftDue = .none
                }
                isInputFocused = true
            }
        }
    }

    /// 把键盘焦点给输入框。激活 Atoll 与设 key window 已由快捷键处理里的
    /// `TodoKeyboardFocus.begin(window:)` 同步完成，这里只负责 SwiftUI 侧的焦点。
    ///
    /// 视图刚创建时同一轮设置的焦点可能被忽略，所以下一轮 runloop 设一次、稍后再补一次。
    ///
    /// 文本框获得焦点时 AppKit 默认全选，接着打字会把保留的草稿整段替换掉。
    /// 每次聚焦后把字段编辑器的光标移到末尾，打字就是续写。App 最低支持 macOS 14.6，
    /// SwiftUI 的 TextSelection 要 macOS 15，所以直接操作字段编辑器。
    private func focusInput() {
        let focusAndPlaceCursorAtEnd = {
            isInputFocused = true
            // 焦点落定、字段编辑器接管之后才能改选区，所以再等一轮 runloop
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
        DispatchQueue.main.async(execute: focusAndPlaceCursorAtEnd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: focusAndPlaceCursorAtEnd)
    }
}

// MARK: - 单条待办

/// 待办列表里的一行：左侧圆圈勾选完成，右侧显示截止标签，右键可删除。
private struct TodoRow: View {
    let item: TodoItem
    let isCompleting: Bool
    let onComplete: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isCompleting ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            .help("Mark as done")

            Text(item.title)
                .font(.system(size: 12))
                .strikethrough(isCompleting)
                .foregroundStyle(isCompleting ? Color.secondary : Color.primary)
                .lineLimit(2).truncationMode(.tail)

            Spacer(minLength: 4)

            if let label = TodoLogic.dueLabel(for: item, now: .now, calendar: .current) {
                Text(label.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(label.isOverdue ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(isHovered ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isCompleting ? 0.5 : 1)
        .animation(.easeOut(duration: 0.2), value: isCompleting)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Mark as done"), onComplete)
        .accessibilityAction(named: Text("Delete"), onDelete)
    }
}
