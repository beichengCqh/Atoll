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
/// 输入框才收得到键盘；刘海收起后要把焦点还回去，否则之后的按键会落进已收起的刘海面板。
///
/// 一次借还是一个会话：`begin` 开启并记下借之前的焦点，`end` 在刘海收起时排一次延时归还。
/// 延时期间再次 `begin`（收起后马上又按快捷键）会取消归还、沿用原会话，焦点仍按最初的状态还。
@MainActor
enum TodoKeyboardFocus {
    /// 借焦点前的状态。窗口用弱引用：窗口被系统销毁（如拔掉显示器）时不延长它的生命周期。
    private final class Session {
        let returnApp: NSRunningApplication?
        weak var previousKeyWindow: NSWindow?
        weak var borrowedWindow: NSWindow?

        init(returnApp: NSRunningApplication?, previousKeyWindow: NSWindow?) {
            self.returnApp = returnApp
            self.previousKeyWindow = previousKeyWindow
        }
    }

    private static var session: Session?
    private static var pendingReturn: Task<Void, Never>?

    /// 收起后等这么久再归还：点击其他 App 收起刘海时，让那个 App 先完成激活。
    private static let returnDelay: Duration = .milliseconds(150)

    /// 快捷键打开待办页时同步调用：记下借之前的焦点，激活 Atoll，把刘海窗口设为 key window。
    ///
    /// 在快捷键处理里同步完成，而不是等待办页渲染出来：这样渲染期间敲下的字也会排进刘海窗口。
    static func begin(window: NSWindow) {
        pendingReturn?.cancel()
        pendingReturn = nil

        if session == nil {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let frontmost = NSWorkspace.shared.frontmostApplication
            let returnApp = frontmost?.processIdentifier == ownPID ? nil : frontmost
            // Atoll 已在前台时记下当时的 key window（如设置窗口），收起后优先还给它
            let currentKey = NSApp.isActive ? NSApp.keyWindow : nil
            session = Session(returnApp: returnApp, previousKeyWindow: currentKey === window ? nil : currentKey)
        }
        session?.borrowedWindow = window

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKey()
    }

    /// 刘海收起时调用（任何收起方式都走这里）。没有借焦点会话时什么都不做。
    static func end() {
        guard let current = session, pendingReturn == nil else { return }
        pendingReturn = Task { @MainActor in
            try? await Task.sleep(for: returnDelay)
            guard !Task.isCancelled else { return }
            session = nil
            pendingReturn = nil
            restore(current)
        }
    }

    private static func restore(_ session: Session) {
        let keyWindow = NSApp.keyWindow
        let decision = TodoFocusPolicy.decide(
            atollIsActive: NSApp.isActive,
            keyWindowIsOther: keyWindow != nil && keyWindow !== session.borrowedWindow,
            previousWindowAvailable: session.previousKeyWindow?.isVisible == true,
            returnAppAvailable: session.returnApp.map { !$0.isTerminated } ?? false
        )
        switch decision {
        case .keep:
            break
        case .previousWindow:
            session.previousKeyWindow?.makeKeyAndOrderFront(nil)
        case .returnApp:
            session.returnApp?.activate(options: [])
        case .deactivate:
            NSApp.deactivate()
        }
    }
}
