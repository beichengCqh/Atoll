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

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// inbox 在灵动岛**收起态**的常驻角标：左翼一个托盘图标，右翼一个计数。
///
/// 本视图只负责画。是否出现在刘海上由 ContentView 的收起态优先级链决定，
/// 这里不做任何显示与否的判断。
struct InboxLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var manager = ClaudeInboxManager.shared

    /// 左右两翼各自的外侧留白。数值与 ReminderLiveActivity 一致，
    /// 保证多个收起态活动轮流出现时图标横向位置不跳。
    private let wingPadding: CGFloat = 16
    private let countFontSize: CGFloat = 16

    /// 刘海当前的可用高度。为 0 时（隐藏刘海）整个角标塌缩成零高度，交给上层决定去留。
    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: leftWingWidth, height: notchContentHeight)
                .background(alignment: .leading) {
                    iconSection
                        .padding(.leading, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }

            // 刘海本体：必须填纯黑，让这段和物理挖孔连成一片
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            Color.clear
                .frame(width: rightWingWidth, height: notchContentHeight)
                .background(alignment: .trailing) {
                    countSection
                        .padding(.trailing, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
        }
        .frame(height: notchContentHeight, alignment: .center)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - 两翼内容

    private var iconSection: some View {
        Image(systemName: "tray.full.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: iconDiameter, height: notchContentHeight, alignment: .center)
            .animation(.smooth(duration: 0.25), value: accent)
    }

    private var countSection: some View {
        Text("\(displayCount)")
            .font(.system(size: countFontSize, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(accent)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: false))
            .animation(.smooth(duration: 0.25), value: displayCount)
            .frame(height: notchContentHeight, alignment: .center)
    }

    // MARK: - 显示内容取舍

    /// 角标里只放**一个**数字：有待确认就显示待确认数，否则显示运行中数。
    ///
    /// 右翼在外接显示器或小屏上只有几十点宽，塞两个数字会被裁掉一半，
    /// 那比少显示一个数字更糟——完整信息在展开后的列表里。
    private var displayCount: Int {
        manager.pendingCount > 0 ? manager.pendingCount : manager.runningCount
    }

    /// 图标与数字取同一个状态的 tint：待确认橙、运行中蓝。
    /// 颜色和数字必须来自同一个判断，否则会出现"橙色配着运行中数量"这种自相矛盾的显示。
    private var accent: Color {
        manager.pendingCount > 0 ? InboxStatus.needsInput.tint : InboxStatus.running.tint
    }

    // MARK: - 尺寸

    private var leftWingWidth: CGFloat {
        wingPadding + iconDiameter
    }

    /// 右翼按数字的实测宽度收缩，位数从 1 变到 2 时不会在旁边留一块空档。
    /// 下限 34 保证单字符时右翼不会窄到把数字压在刘海边缘上。
    private var rightWingWidth: CGFloat {
        let font = monospacedDigitFont(size: countFontSize, weight: .semibold)
        let width = measureTextWidth("\(displayCount)", font: font)
        return wingPadding + max(width + 18, 34)
    }

    /// 图标占位直径。跟随刘海高度收缩，下限 26 保证矮刘海上图标不被压扁。
    private var iconDiameter: CGFloat {
        max(notchContentHeight - 8, 26)
    }

    private func measureTextWidth(_ text: String, font: PlatformFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    /// 等宽数字字体，用于测宽。与 `countSection` 的 `.monospacedDigit()` 对应，
    /// 两处必须同源，否则测出来的宽度和实际渲染宽度对不上。
    private func monospacedDigitFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        #if canImport(AppKit)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        #else
        return UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        #endif
    }
}
