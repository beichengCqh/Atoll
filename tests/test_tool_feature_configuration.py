import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ToolFeatureConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.generic_source = (ROOT / "DynamicIsland/enums/generic.swift").read_text()
        self.constants_source = (ROOT / "DynamicIsland/models/Constants.swift").read_text()
        self.coordinator_source = (ROOT / "DynamicIsland/DynamicIslandViewCoordinator.swift").read_text()
        self.tab_source = (ROOT / "DynamicIsland/components/Tabs/TabSelectionView.swift").read_text()
        self.content_source = (ROOT / "DynamicIsland/ContentView.swift").read_text()
        self.sizing_source = (ROOT / "DynamicIsland/sizing/matters.swift").read_text()
        self.settings_source = (ROOT / "DynamicIsland/components/Settings/SettingsView.swift").read_text()
        self.gitignore_source = (ROOT / ".gitignore").read_text()

    def test_tool_view_is_registered(self):
        self.assertIn("case tool", self.generic_source)
        self.assertIn(".tool", self.coordinator_source)
        self.assertIn(
            'TabModel(label: "Tool", icon: "wrench.and.screwdriver", view: .tool)',
            self.tab_source,
        )
        self.assertIn("case .tool:", self.content_source)
        self.assertIn("NotchToolView()", self.content_source)

    def test_tool_feature_defaults_to_enabled(self):
        self.assertIn(
            'Key<Bool>("enableToolFeature", default: true)',
            self.constants_source,
        )
        self.assertIn("@Default(.enableToolFeature)", self.tab_source)
        self.assertIn("Defaults[.enableToolFeature]", self.sizing_source)
        self.assertIn("handleToolFeatureToggle(change.newValue)", self.coordinator_source)
        self.assertIn("currentView == .tool", self.coordinator_source)

    def test_tool_settings_are_available(self):
        self.assertIn("case tools", self.settings_source)
        self.assertIn("ToolSettings()", self.settings_source)
        self.assertIn("Defaults.Toggle(key: .enableToolFeature)", self.settings_source)
        self.assertIn(
            ".colorPicker,\n            .tools,\n            .shelf,",
            self.settings_source,
        )
        self.assertIn("SettingsSearchEntry(tab: .tools", self.settings_source)

    def test_tool_view_exposes_both_converters(self):
        tool_view_path = ROOT / "DynamicIsland/components/Tool/NotchToolView.swift"
        self.assertTrue(tool_view_path.exists())

        tool_view_source = tool_view_path.read_text()
        self.assertIn("ToolConverter.encodeBase64", tool_view_source)
        self.assertIn("ToolConverter.decodeBase64", tool_view_source)
        self.assertIn("ToolConverter.dateString", tool_view_source)
        self.assertIn("ToolConverter.timestamps", tool_view_source)
        self.assertIn("NSPasteboard.general", tool_view_source)
        self.assertIn('Button("Convert")', tool_view_source)

    def test_tool_regression_tests_are_trackable(self):
        self.assertIn("!tests/test_tool_converter.py", self.gitignore_source)
        self.assertIn("!tests/test_tool_feature_configuration.py", self.gitignore_source)


if __name__ == "__main__":
    unittest.main()
