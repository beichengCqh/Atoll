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

/// 待办快捷键「打开即输入」期间的键盘焦点借还。
///
/// 刘海面板平时不激活 Atoll。快捷键打开待办页时要先激活 Atoll、把刘海窗口设为 key window，
/// 输入框才收得到键盘；刘海收起后要把前台还给原来的 App，否则之后的按键会落进已收起的刘海面板。
@MainActor
enum TodoKeyboardFocus {
    /// 借焦点前的前台 App；只有经快捷键借过焦点时才有值。
    private static var returnApp: NSRunningApplication?

    /// 收起后等这么久再判断是否归还：点击其他 App 收起刘海时，让那个 App 先完成激活。
    private static let returnDelay: Duration = .milliseconds(150)

    /// 快捷键打开待办页时同步调用：记下当前前台 App，激活 Atoll，把刘海窗口设为 key window。
    ///
    /// 在快捷键处理里同步完成，而不是等待办页渲染出来：这样渲染期间敲下的字也会排进刘海窗口。
    static func begin(window: NSWindow) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnApp = frontmost
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKey()
    }

    /// 刘海收起时调用（任何收起方式都走这里）。没借过焦点时什么都不做。
    ///
    /// 延迟后若前台仍是 Atoll（快捷键再按一次、Esc、鼠标移出收起），把前台还给原 App；
    /// 若已是别的 App（用户点击其他窗口收起），说明焦点已经自然交出，不再抢回原 App。
    static func end() {
        guard let app = returnApp else { return }
        returnApp = nil
        Task { @MainActor in
            try? await Task.sleep(for: returnDelay)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID else { return }
            if app.isTerminated {
                NSApp.deactivate()
            } else {
                app.activate(options: [])
            }
        }
    }
}
