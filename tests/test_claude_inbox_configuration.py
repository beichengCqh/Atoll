"""Claude Inbox 接入点回归测试。

本仓没有针对 app 逻辑的 XCTest，新功能靠读 Swift 源码文本逐条断言接入点是否都在。
这份文件专守「漏了编译器也不会报错」的那几个坑：手写的 `==`、`bypassedTypes` 白名单、
设置侧栏与搜索索引。漏掉任何一个，功能都会**静默失效**——不崩溃、不报错、只是不工作。
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "DynamicIsland"


def find_source(filename):
    """在 DynamicIsland/ 下按文件名递归查找，返回首个命中路径，找不到返回 None。

    不写死目录，允许实现方自行决定文件落在 components/ 还是 managers/ 下。
    """
    return next(SOURCE_ROOT.rglob(filename), None)


def slice_between(source, start_marker, end_marker):
    """截取 start_marker 之后、其后首个 end_marker 之前的片段；任一标记缺失时返回空串。

    用来把断言限定在某个函数体或某个数组字面量内部，避免同名符号在文件别处出现就误判通过。
    """
    start = source.find(start_marker)
    if start == -1:
        return ""
    start += len(start_marker)
    end = source.find(end_marker, start)
    if end == -1:
        return ""
    return source[start:end]


class ClaudeInboxConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.generic_source = (SOURCE_ROOT / "enums/generic.swift").read_text()
        self.constants_source = (SOURCE_ROOT / "models/Constants.swift").read_text()
        self.coordinator_source = (SOURCE_ROOT / "DynamicIslandViewCoordinator.swift").read_text()
        self.tab_source = (SOURCE_ROOT / "components/Tabs/TabSelectionView.swift").read_text()
        self.content_source = (SOURCE_ROOT / "ContentView.swift").read_text()
        self.sizing_source = (SOURCE_ROOT / "sizing/matters.swift").read_text()
        self.settings_source = (SOURCE_ROOT / "components/Settings/SettingsView.swift").read_text()
        self.gitignore_source = (ROOT / ".gitignore").read_text()

    def test_inbox_view_is_registered(self):
        self.assertIn(
            "case inbox",
            self.generic_source,
            "NotchViews 缺 case inbox（DynamicIsland/enums/generic.swift）："
            "没有这个 case，展开后就没有可切换到的 inbox 页。",
        )
        self.assertIn(
            "case .inbox:",
            self.content_source,
            "ContentView 的 currentView switch 缺 case .inbox:"
            "（DynamicIsland/ContentView.swift 约 1095 行）：切到 inbox 标签会渲染不出任何内容。",
        )
        self.assertIn(
            "NotchInboxView()",
            self.content_source,
            "ContentView 的 case .inbox: 没有渲染 NotchInboxView()"
            "（DynamicIsland/ContentView.swift）：整页列表永远打不开。",
        )

    def test_inbox_tab_is_appended(self):
        self.assertIn(
            "view: .inbox)",
            self.tab_source,
            "TabSelectionView 没有追加 inbox 的 TabModel"
            "（DynamicIsland/components/Tabs/TabSelectionView.swift 约 100 行）："
            "标签栏里不会出现 Inbox，用户没有入口点进整页列表。",
        )
        self.assertIn(
            "enableClaudeInbox",
            self.tab_source,
            "TabSelectionView 没有按 enableClaudeInbox 门禁 inbox 标签"
            "（DynamicIsland/components/Tabs/TabSelectionView.swift）："
            "功能开关关掉后标签依然常驻，占掉一格标签宽度。",
        )
        self.assertIn(
            ".inbox",
            slice_between(self.coordinator_source, "private static let tabOrder", "\n"),
            "tabOrder 数组缺 .inbox（DynamicIsland/DynamicIslandViewCoordinator.swift 约 108 行）："
            "firstIndex(of:) 找不到会回落成 0，切进/切出 inbox 的过场动画方向恒为反向。",
        )

    def test_inbox_defaults_exist(self):
        self.assertIn(
            'Key<Bool>("enableClaudeInbox"',
            self.constants_source,
            "Defaults 缺 enableClaudeInbox（DynamicIsland/models/Constants.swift）："
            "整个功能没有总开关，标签栏与设置页都无从门禁。",
        )
        self.assertIn(
            'Key<Date>("inboxMutedUntil"',
            self.constants_source,
            "Defaults 缺 inboxMutedUntil（DynamicIsland/models/Constants.swift）："
            "静音状态无处持久化，重启 Atoll 后静音自动失效。",
        )

    def test_sneak_content_type_is_fully_wired(self):
        """SneakContentType 新增 case 必须同步改三处，漏任何一处编译器都不会报错。"""
        self.assertIn(
            "case claudeInbox",
            self.coordinator_source,
            "SneakContentType 缺 case claudeInbox"
            "（DynamicIsland/DynamicIslandViewCoordinator.swift 约 43 行）：横幅没有自己的类型标识。",
        )

        # 手写 `==` 的元组串必须显式列出新 case，否则它落进 default: return false，
        # 结果是 .claudeInbox 跟它自己都不相等，横幅的显示判定永远为假。
        equality_true_branch = slice_between(
            self.coordinator_source,
            "static func == (lhs: SneakContentType, rhs: SneakContentType)",
            "default:",
        )
        self.assertNotEqual(
            "",
            equality_true_branch,
            "找不到 SneakContentType 手写的 == 实现"
            "（DynamicIsland/DynamicIslandViewCoordinator.swift 约 47 行）："
            "该函数被改名或删除后，本测试守不住下面那条断言，请同步修正这里的定位标记。",
        )
        self.assertIn(
            "(.claudeInbox, .claudeInbox)",
            equality_true_branch,
            "手写的 == 元组串里没有 (.claudeInbox, .claudeInbox)"
            "（DynamicIsland/DynamicIslandViewCoordinator.swift 约 43-57 行）："
            "新 case 会落进 default: return false，导致 .claudeInbox 跟自己都不相等，"
            "横幅永不显示，且编译器全程不报错。",
        )

        # bypassedTypes 是「用户没开 HUD 替换时依然放行」的白名单。
        bypassed_line = next(
            (line for line in self.coordinator_source.splitlines() if "let bypassedTypes" in line),
            "",
        )
        self.assertNotEqual(
            "",
            bypassed_line,
            "找不到 bypassedTypes 声明"
            "（DynamicIsland/DynamicIslandViewCoordinator.swift 约 367 行）："
            "该变量被改名后，本测试守不住白名单，请同步修正这里的定位标记。",
        )
        self.assertIn(
            ".claudeInbox",
            bypassed_line,
            "bypassedTypes 白名单缺 .claudeInbox"
            "（DynamicIsland/DynamicIslandViewCoordinator.swift 约 367 行）："
            "用户没打开 enableSystemHUD 时 toggleSneakPeek 会提前 return，横幅静默丢失。",
        )

    def test_inbox_tab_counts_toward_notch_width(self):
        inbox_counted = slice_between(
            self.sizing_source,
            "func enabledStandardTabCount()",
            "return count",
        )
        self.assertIn(
            "enableClaudeInbox",
            inbox_counted,
            "enabledStandardTabCount() 没有统计 inbox 标签"
            "（DynamicIsland/sizing/matters.swift 约 62 行）："
            "开启 inbox 后标签数被少算一格，刘海最小宽度不够，标签栏会被挤到换行或截断。",
        )

    def test_inbox_settings_are_available(self):
        self.assertTrue(
            re.search(r"^\s*case inbox$", self.settings_source, re.MULTILINE),
            "SettingsTab 枚举缺 case inbox"
            "（DynamicIsland/components/Settings/SettingsView.swift）：设置页没有 Inbox 这一项。",
        )

        ordered_tabs = slice_between(
            self.settings_source,
            "let ordered: [SettingsTab] = [",
            "]",
        )
        self.assertNotEqual(
            "",
            ordered_tabs,
            "找不到 availableTabs 里的 ordered 数组"
            "（DynamicIsland/components/Settings/SettingsView.swift 约 485 行）："
            "该数组被改写后，本测试守不住侧栏可见性，请同步修正这里的定位标记。",
        )
        self.assertIn(
            ".inbox",
            ordered_tabs,
            "availableTabs 的 ordered 数组缺 .inbox"
            "（DynamicIsland/components/Settings/SettingsView.swift 约 485 行）："
            "枚举里加了 case 也没用，设置侧栏不会显示 Inbox，用户找不到开关，且编译器不报错。",
        )

        self.assertIn(
            "SettingsSearchEntry(tab: .inbox",
            self.settings_source,
            "settingsSearchIndex 没有 inbox 条目"
            "（DynamicIsland/components/Settings/SettingsView.swift 约 701 行）："
            "设置页搜索框搜 inbox 搜不到任何结果，且编译器不报错。",
        )

    def test_inbox_sources_exist(self):
        """契约层两个文件按固定路径校验，其余实现文件只校验存在与核心声明。"""
        contract_files = [
            "DynamicIsland/managers/ClaudeInbox/InboxMessage.swift",
            "DynamicIsland/managers/ClaudeInbox/InboxLocation.swift",
        ]
        for relative in contract_files:
            with self.subTest(file=relative):
                self.assertTrue(
                    (ROOT / relative).exists(),
                    f"契约层文件缺失：{relative}。"
                    "InboxMessage / InboxLocation 是所有 inbox 代码对齐的类型与路径定义，缺了整个模块无从编译。",
                )

        # 文件名 → 必须出现的核心声明。只校验声明在，避免留下空壳文件也算通过。
        implementation_files = {
            "InboxStore.swift": "class InboxStore",
            "InboxSpoolWatcher.swift": "class InboxSpoolWatcher",
            "ClaudeInboxManager.swift": "class ClaudeInboxManager",
            "NotchInboxView.swift": "struct NotchInboxView",
            "InboxLiveActivity.swift": "struct InboxLiveActivity",
        }
        for filename, declaration in implementation_files.items():
            with self.subTest(file=filename):
                path = find_source(filename)
                self.assertIsNotNone(
                    path,
                    f"实现文件缺失：DynamicIsland/ 下找不到 {filename}。"
                    "五个实现文件缺任何一个，inbox 都跑不起来："
                    "InboxStore 存条目、InboxSpoolWatcher 监听投递目录、"
                    "ClaudeInboxManager 串联两者并对外发布、"
                    "NotchInboxView 是展开后的整页列表、InboxLiveActivity 是收起态角标。",
                )
                self.assertIn(
                    declaration,
                    path.read_text(),
                    f"{filename} 里找不到 `{declaration}`：文件在但核心类型没声明，接入点会编译失败。",
                )

    def test_inbox_regression_tests_are_trackable(self):
        self.assertIn(
            "!tests/test_claude_inbox_configuration.py",
            self.gitignore_source,
            ".gitignore 缺 `!tests/test_claude_inbox_configuration.py`（约 142-145 行的白名单段）："
            "tests/ 下的 *.py 被整体忽略，只有显式取反的文件才进版本控制，"
            "漏了这行本测试根本提交不上去，等于没写。",
        )


if __name__ == "__main__":
    unittest.main()
