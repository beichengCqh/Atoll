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

/// 待办快捷键借过键盘焦点后，刘海收起时焦点的去向。
enum TodoFocusReturn: Equatable, Sendable {
    /// 保持现状：用户已切到别的 App，或焦点已落在 Atoll 的其他窗口（如设置窗口）。
    case keep
    /// 还给借焦点前 Atoll 自己的 key window，例如按快捷键时正开着的设置窗口。
    case previousWindow
    /// 还给借焦点前的前台 App。
    case returnApp
    /// 只让出前台，由系统交还给上一个 App；借焦点时 Atoll 已在前台、又没有可还的窗口时走这里。
    case deactivate
}

/// 焦点归还的判定规则。只依赖 Foundation，tests/todo_probe.swift 逐个场景验证。
enum TodoFocusPolicy {
    /// 按收起那一刻的状态决定焦点去向。
    ///
    /// - Parameters:
    ///   - atollIsActive: Atoll 此刻是否仍是前台 App；不是说明用户已自己切走。
    ///   - keyWindowIsOther: Atoll 此刻的 key window 是否是刘海面板以外的窗口。
    ///   - previousWindowAvailable: 借焦点前 Atoll 自己的 key window 是否还在、可见。
    ///   - returnAppAvailable: 借焦点前的前台 App 是否记录在案且仍在运行。
    static func decide(
        atollIsActive: Bool,
        keyWindowIsOther: Bool,
        previousWindowAvailable: Bool,
        returnAppAvailable: Bool
    ) -> TodoFocusReturn {
        guard atollIsActive, !keyWindowIsOther else { return .keep }
        if previousWindowAvailable { return .previousWindow }
        if returnAppAvailable { return .returnApp }
        return .deactivate
    }
}
