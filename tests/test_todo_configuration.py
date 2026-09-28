"""Todo 待办功能的回归测试。

两部分：
1. 接入点文本断言。待办页要在 tab 栏、内容区、尺寸、设置侧栏、搜索索引、快捷键多处接入，
   漏掉任何一处编译器都不报错，功能只是静默不出现。每天自动合并上游时最容易被冲掉的也是这些行。
2. 编译并运行 tests/todo_probe.swift，真跑一遍标题清洗、截止日期换算、排序与截止标签的纯逻辑。
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "DynamicIsland"
PROBE_SOURCES = [
    SOURCE_ROOT / "managers/Todo/TodoItem.swift",
    SOURCE_ROOT / "managers/Todo/TodoFocusPolicy.swift",
    ROOT / "tests/todo_probe.swift",
]


def slice_between(source, start_marker, end_marker):
    """截取 start_marker 之后、其后首个 end_marker 之前的片段；任一标记缺失时返回空串。

    把断言限定在某个函数体或数组字面量内部，避免同名符号在文件别处出现就误判通过。
    """
    start = source.find(start_marker)
    if start == -1:
        return ""
    start += len(start_marker)
    end = source.find(end_marker, start)
    if end == -1:
        return ""
    return source[start:end]


class TodoConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.generic_source = (SOURCE_ROOT / "enums/generic.swift").read_text()
        self.constants_source = (SOURCE_ROOT / "models/Constants.swift").read_text()
        self.shortcut_source = (SOURCE_ROOT / "Shortcuts/ShortcutConstants.swift").read_text()
        self.coordinator_source = (SOURCE_ROOT / "DynamicIslandViewCoordinator.swift").read_text()
        self.tab_source = (SOURCE_ROOT / "components/Tabs/TabSelectionView.swift").read_text()
        self.content_source = (SOURCE_ROOT / "ContentView.swift").read_text()
        self.sizing_source = (SOURCE_ROOT / "sizing/matters.swift").read_text()
        self.settings_source = (SOURCE_ROOT / "components/Settings/SettingsView.swift").read_text()
        self.todo_settings_source = (SOURCE_ROOT / "components/Settings/TodoSettings.swift").read_text()
        self.app_source = (SOURCE_ROOT / "DynamicIslandApp.swift").read_text()
        self.gitignore_source = (ROOT / ".gitignore").read_text()

    def test_notch_view_is_registered(self):
        self.assertIn("case todo", self.generic_source, "NotchViews 缺 case todo")
        self.assertIn("case .todo:", self.content_source, "ContentView 的内容 switch 缺 .todo 分支")
        self.assertIn("NotchTodoView()", self.content_source, "ContentView 没有渲染 NotchTodoView")
        self.assertIn(
            "coordinator.currentView == .todo",
            self.content_source,
            "ContentView 没给待办页设置高度，列表会被压成默认高度",
        )

    def test_tab_is_shown_and_counted(self):
        tabs = slice_between(self.tab_source, "private var tabs: [TabModel]", "var body: some View")
        self.assertIn("view: .todo", tabs, "tab 栏没有追加 Todo 标签")
        self.assertIn(
            "@Default(.enableTodoFeature)",
            self.tab_source,
            "TabSelectionView 缺 @Default(.enableTodoFeature)：开关切换后 tab 栏不会重新求值",
        )
        self.assertIn("Defaults[.enableTodoFeature]", self.sizing_source, "matters.swift 的 tab 计数漏了待办页")

    def test_coordinator_tracks_todo(self):
        order = slice_between(self.coordinator_source, "tabOrder: [NotchViews] = [", "]")
        self.assertIn(".todo", order, "tabOrder 缺 .todo，切换动画方向会错")
        # 断言订阅调用点而不是函数名：只有函数定义、订阅被合并冲掉时也必须报警
        self.assertIn(
            "self?.handleTodoFeatureToggle(change.newValue)",
            self.coordinator_source,
            "关闭待办功能时没有退回首页，会停在一个已经不存在的 tab 上",
        )
        self.assertIn(
            "Defaults.publisher(.enableTodoFeature).map",
            self.coordinator_source,
            "开关待办功能后没有重算刘海最小宽度",
        )

    def test_defaults_keys_exist(self):
        self.assertRegex(self.constants_source, r'Key<Bool>\("enableTodoFeature", default: true\)')
        self.assertRegex(self.constants_source, r'Key<String>\("todoReminderListID", default: ""\)')

    def test_shortcut_is_defined_and_wired(self):
        self.assertIn('Self("toggleTodoTab"', self.shortcut_source)
        self.assertIn("onKeyDown(for: .toggleTodoTab)", self.app_source, "快捷键没有注册处理函数")
        availability = slice_between(
            self.app_source, "private func updateFeatureShortcutAvailability()", "\n    }\n"
        )
        self.assertIn(
            "updateShortcut(.toggleTodoTab",
            availability,
            "关闭待办功能或全局快捷键时，待办快捷键没有跟着停用",
        )
        handler = slice_between(self.app_source, "onKeyDown(for: .toggleTodoTab)", "KeyboardShortcuts.onKeyDown(for:")
        self.assertIn("requestInputFocus()", handler, "快捷键打开待办页后没有请求聚焦输入框")
        self.assertIn(
            "TodoKeyboardFocus.begin(window:",
            handler,
            "快捷键没有同步激活 Atoll 并设 key window，打开后立刻敲的字会落进原来的 App",
        )
        self.assertIn(
            "TodoKeyboardFocus.markKeyboardClose(of:",
            handler,
            "快捷键收起时没有标记键盘收起，归还焦点前会多出 150ms 的丢键窗口",
        )
        self.assertIn(
            "NSScreen.screenWithMouse",
            handler,
            "多屏模式下应按 screenWithMouse 选屏：frame.contains 不含屏幕最顶一行，光标停在刘海上时选不到屏",
        )

    def test_keyboard_focus_is_returned_and_notch_can_be_dismissed(self):
        closed_branch = slice_between(self.content_source, "if newState == .closed {", "} else {")
        self.assertIn(
            "TodoKeyboardFocus.end(viewModel: vm)",
            closed_branch,
            "刘海收起时没有归还前台：快捷键收起后 Atoll 仍在前台，之后的按键全部丢失",
        )
        monitor_guard = slice_between(self.content_source, "func syncStickyTerminalOutsideClickMonitor()", "installStickyTerminalClickMonitor()")
        self.assertIn(".todo", monitor_guard, "快捷键打开的待办页点击外部无法收起")
        todo_view = (SOURCE_ROOT / "components/Todo/NotchTodoView.swift").read_text()
        exit_handler = slice_between(todo_view, ".onExitCommand {", "}")
        self.assertIn("markKeyboardClose(of: vm)", exit_handler, "Esc 收起前没有标记键盘收起")
        self.assertIn("vm.close()", exit_handler, "待办页输入框缺 Esc 收起")

    def test_draft_survives_notch_close_and_reopen(self):
        todo_view = (SOURCE_ROOT / "components/Todo/NotchTodoView.swift").read_text()
        manager = (SOURCE_ROOT / "managers/Todo/TodoManager.swift").read_text()
        self.assertIn("@Published var draftTitle", manager, "草稿要放在 TodoManager 上，刘海收起销毁视图后才不会丢")
        self.assertIn("text: $manager.draftTitle", todo_view, "输入框没有绑定到 TodoManager 上的草稿")
        self.assertNotRegex(todo_view, r"@State private var draft\b", "草稿又回到了视图的 @State，刘海收起就会丢")
        focus = slice_between(todo_view, "private func focusInput()", "\n    }\n")
        self.assertIn(
            "setSelectedRange(",
            focus,
            "聚焦时没有把光标放到草稿末尾：文本框默认全选，快捷键重开后敲第一个字就会覆盖草稿",
        )
        # App 最低支持 macOS 14.6，TextSelection 要 macOS 15，用了就编译失败（CI 实发过一次）。
        # 只查代码不查注释：注释里说明为什么不用它是允许的
        code = re.sub(r"//[^\n]*", "", todo_view)
        self.assertNotIn("TextSelection", code, "用了 macOS 15 才有的 TextSelection，最低 14.6 的 App 编译会失败")

    def test_settings_does_not_prompt_when_disabled(self):
        # 断言任务体里先判断开关再读取：只留 .task(id:) 而丢了 guard 时同样会弹权限框。
        # 先去掉行注释并拒绝条件编译，guard 被注释掉或包进 #if false 时也要报警
        code = re.sub(r"//[^\n]*", "", self.todo_settings_source)
        self.assertNotIn("#if", code, "TodoSettings 里出现条件编译，开关判断可能被编译掉")
        self.assertEqual(
            1,
            code.count("manager.activate("),
            "TodoSettings 只能在受开关保护的 task 里读取提醒事项，其他调用点会绕过开关弹权限框",
        )
        body = slice_between(code, ".task(id: enableTodoFeature) {", "\n        }\n")
        guard_at = body.find("guard enableTodoFeature else { return }")
        activate_at = body.find("manager.activate(")
        self.assertNotEqual(-1, guard_at, "设置页读取提醒事项前没有判断功能开关，关闭功能时打开设置页也会弹权限框")
        self.assertNotEqual(-1, activate_at, "设置页没有在功能开启时读取提醒事项")
        self.assertLess(guard_at, activate_at, "功能开关判断必须在读取提醒事项之前")

    def test_settings_tab_and_search_entries(self):
        self.assertIn("case todo", self.settings_source, "SettingsTab 缺 case todo")
        ordered = slice_between(self.settings_source, "let ordered: [SettingsTab] = [", "]")
        self.assertIn(".todo", ordered, "设置侧栏没有列出待办页")
        self.assertIn("TodoSettings(highlightID:", self.settings_source, "设置详情没有渲染 TodoSettings")

        # 搜索条目的 title 必须与 TodoSettings 里 highlightID(...) 的字符串逐字一致，否则跳转后不高亮
        entry_titles = set(re.findall(r'SettingsSearchEntry\(tab: \.todo, title: "([^"]+)"', self.settings_source))
        highlight_titles = set(re.findall(r'highlightID\("([^"]+)"\)', self.todo_settings_source))
        self.assertTrue(entry_titles, "搜索索引里没有待办页条目")
        self.assertEqual(entry_titles, highlight_titles, "搜索条目与设置页高亮标题不一致")

    def test_test_files_are_tracked(self):
        self.assertIn("!tests/test_todo_configuration.py", self.gitignore_source)


class TodoProbeTests(unittest.TestCase):
    def test_probe_passes(self):
        if shutil.which("swiftc") is None:
            self.skipTest("swiftc is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "todo_probe"
            compiled = subprocess.run(
                ["swiftc", "-o", str(executable), *map(str, PROBE_SOURCES)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            # 编译失败时把 swiftc 的诊断带进断言信息，CI 日志里才看得到错在哪
            self.assertEqual(0, compiled.returncode, compiled.stderr)
            result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
