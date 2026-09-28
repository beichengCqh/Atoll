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
/// 一次借还是一个会话，绑定借焦点的那块刘海（view model）：
/// - `begin` 开启会话并记下借之前的焦点；
/// - 这块刘海收起时 `end` 归还，其他屏幕的刘海收起不影响会话；
/// - 键盘收起（Esc、再按快捷键）立即归还；鼠标收起延时归还，让用户点中的 App 先完成激活；
/// - 延时期间再次 `begin`（收起后马上又按快捷键）会取消归还、沿用原会话。
@MainActor
enum TodoKeyboardFocus {
    /// 借焦点前的状态。窗口与 view model 用弱引用：屏幕配置变化拆掉刘海时不延长它们的生命周期。
    private final class Session {
        let returnApp: NSRunningApplication?
        weak var previousKeyWindow: NSWindow?
        weak var borrowedWindow: NSWindow?
        weak var viewModel: DynamicIslandViewModel?
        /// 借焦点时已经可见的窗口；收起时不在其中的可见普通窗口，就是借焦点期间新打开的。
        let preexistingWindows: Set<ObjectIdentifier>

        init(returnApp: NSRunningApplication?, previousKeyWindow: NSWindow?, preexistingWindows: Set<ObjectIdentifier>) {
            self.returnApp = returnApp
            self.previousKeyWindow = previousKeyWindow
            self.preexistingWindows = preexistingWindows
        }
    }

    private static var session: Session?
    private static var pendingReturn: Task<Void, Never>?
    /// 下一次收起来自键盘（Esc 或快捷键），归还不必等待。
    private static var keyboardCloseRequested = false

    /// 鼠标收起后等这么久再归还：点击其他 App 收起刘海时，让那个 App 先完成激活。
    private static let mouseCloseDelay: Duration = .milliseconds(150)

    /// 快捷键打开待办页时同步调用：记下借之前的焦点，激活 Atoll，把刘海窗口设为 key window。
    ///
    /// 在快捷键处理里同步完成，而不是等待办页渲染出来：这样渲染期间敲下的字也会排进刘海窗口。
    static func begin(window: NSWindow, viewModel: DynamicIslandViewModel) {
        pendingReturn?.cancel()
        pendingReturn = nil
        keyboardCloseRequested = false

        // 上一个会话的刘海已被拆掉或已收起却没走到归还（如屏幕配置变化），它记的焦点已经过期
        if let stale = session, stale.viewModel == nil || stale.viewModel?.notchState != .open {
            session = nil
        }
        if session == nil {
            session = makeSession(borrowing: window)
        }
        session?.borrowedWindow = window
        session?.viewModel = viewModel

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKey()
    }

    /// 由键盘收起借了焦点的刘海前调用（Esc、再按一次快捷键），让随后的归还立即执行。
    static func markKeyboardClose(of viewModel: DynamicIslandViewModel) {
        guard session?.viewModel === viewModel else { return }
        keyboardCloseRequested = true
    }

    /// 刘海收起时调用（任何收起方式都走这里）。只处理借了焦点的那块刘海，其他情况什么都不做。
    static func end(viewModel: DynamicIslandViewModel) {
        guard let current = session, current.viewModel === viewModel, pendingReturn == nil else { return }
        let delay: Duration = keyboardCloseRequested ? .zero : mouseCloseDelay
        keyboardCloseRequested = false
        pendingReturn = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            session = nil
            pendingReturn = nil
            restore(current)
        }
    }

    // MARK: - Private

    private static func makeSession(borrowing window: NSWindow) -> Session {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let returnApp = frontmost?.processIdentifier == ownPID ? nil : frontmost
        // Atoll 已在前台时记下当时的 key window（如设置窗口）；任何屏幕的刘海面板都不算，还给它只会吞键
        let currentKey = NSApp.isActive ? NSApp.keyWindow : nil
        let previousKey = currentKey.flatMap { isNotchPanel($0) ? nil : $0 }
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        return Session(returnApp: returnApp, previousKeyWindow: previousKey, preexistingWindows: visible)
    }

    private static func restore(_ session: Session) {
        let keyWindow = NSApp.keyWindow
        let openedWindow = NSApp.windows.first { window in
            isRegularWindow(window) && !session.preexistingWindows.contains(ObjectIdentifier(window))
        }
        let decision = TodoFocusPolicy.decide(
            atollIsActive: NSApp.isActive,
            keyWindowIsOther: keyWindow.map { !isNotchPanel($0) } ?? false,
            openedWindowAvailable: openedWindow != nil,
            previousWindowAvailable: session.previousKeyWindow?.isVisible == true,
            returnAppAvailable: session.returnApp.map { !$0.isTerminated } ?? false
        )
        switch decision {
        case .keep:
            break
        case .openedWindow:
            openedWindow?.makeKeyAndOrderFront(nil)
        case .previousWindow:
            session.previousKeyWindow?.makeKeyAndOrderFront(nil)
        case .returnApp:
            session.returnApp?.activate(options: [])
        case .deactivate:
            NSApp.deactivate()
        }
    }

    private static func isNotchPanel(_ window: NSWindow) -> Bool {
        window is DynamicIslandWindow
    }

    /// 用户会操作的普通窗口（如设置窗口）：可见、带标题栏、普通层级。
    /// 提示条、HUD、锁屏组件等无边框浮层不算，给它们 key 没有意义。
    private static func isRegularWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && window.level == .normal && !isNotchPanel(window)
    }
}
