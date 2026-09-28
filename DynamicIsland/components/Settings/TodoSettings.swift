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
import KeyboardShortcuts
import SwiftUI

/// 待办功能的设置页：开关、写入哪个「提醒事项」列表、权限状态与快捷键。
///
/// `SettingsTab` 是 SettingsView.swift 的文件私有类型，搜索高亮 ID 由调用方按 `.todo` 标签页生成后传入。
/// 各控件的高亮标题必须与 SettingsSearchIndex 里 `.todo` 条目的 title 逐字一致，否则搜索能命中但跳转不高亮。
struct TodoSettings: View {
    let highlightID: (String) -> String

    @ObservedObject private var manager = TodoManager.shared
    @Default(.enableTodoFeature) private var enableTodoFeature
    @Default(.todoReminderListID) private var listID

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableTodoFeature) {
                    Text("Enable Todo")
                }
                .settingsHighlight(id: highlightID("Enable Todo"))
            } header: {
                Text("Todo")
            } footer: {
                Text("Adds a Todo tab to the notch. Todos are saved to Apple Reminders, so they sync to your other devices.")
            }

            if enableTodoFeature {
                Section {
                    accessRow
                    Picker("Reminders list", selection: $listID) {
                        Text("Default list").tag("")
                        ForEach(manager.lists) { list in
                            Text("\(list.title) (\(list.accountTitle))").tag(list.id)
                        }
                    }
                    .disabled(manager.accessState != .granted)
                    .settingsHighlight(id: highlightID("Reminders list"))
                } header: {
                    Text("Storage")
                } footer: {
                    Text("The Todo tab shows open reminders from this list, and new todos are added to it.")
                }

                Section {
                    KeyboardShortcuts.Recorder("Open Todo:", name: .toggleTodoTab)
                        .settingsHighlight(id: highlightID("Open Todo shortcut"))
                } header: {
                    Text("Shortcut")
                } footer: {
                    Text("Opens the notch on the Todo tab with the input field ready for typing. Press it again to close.")
                }
            }
        }
        .navigationTitle("Todo")
        .task { await manager.activate(listID: listID) }
        .onChange(of: listID) { _, newValue in
            Task { await manager.updateListID(newValue) }
        }
    }

    /// 权限状态一行：未决定给申请按钮，已拒绝引导去系统设置，已授权只显示状态。
    @ViewBuilder
    private var accessRow: some View {
        HStack {
            Text("Reminders access")
            Spacer()
            switch manager.accessState {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("Allow Access") {
                    Task { await manager.requestAccess(); await manager.refresh() }
                }
            case .denied:
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
