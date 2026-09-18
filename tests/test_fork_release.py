"""fork 自更新通道的回归测试。

守住三件事：已安装的 fork 版只从 fork 的 Release 拉更新、签名材料成对且私钥不进仓库、
发布流水线的判断与产物格式正确。任何一条被上游合并冲掉，fork 版都会被上游官方包覆盖或收不到更新。
"""

import base64
import importlib.util
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "DynamicIsland" / "Info.plist"
UPDATE_CHANNEL = ROOT / "DynamicIsland" / "models" / "UpdateChannel.swift"
KEY_TOOL = ROOT / "scripts" / "sparkle_key_tool.swift"
RELEASE_SCRIPT = ROOT / "scripts" / "fork_release.py"
SIGNING_DIR = ROOT / "scripts" / "fork_signing"
CERTIFICATE = SIGNING_DIR / "codesign_certificate.pem"
WORKFLOW = ROOT / ".github" / "workflows" / "fork-release.yml"
GITIGNORE = ROOT / ".gitignore"

FORK_FEED = "https://github.com/beichengCqh/Atoll/releases/latest/download/appcast.xml"
UPSTREAM_PUBLIC_KEY = "q2YQaJ1umGkaIJWMGN9Isj5fx/YlUtxnzHEBqFtfZcg="
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def load_release_module():
    spec = importlib.util.spec_from_file_location("fork_release", RELEASE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UpdateFeedConfigurationTests(unittest.TestCase):
    def test_info_plist_points_at_fork_feed_and_key(self):
        info = plistlib.loads(INFO_PLIST.read_bytes())

        self.assertEqual(FORK_FEED, info["SUFeedURL"])
        public_key = info["SUPublicEDKey"]
        self.assertEqual(32, len(base64.b64decode(public_key, validate=True)))
        self.assertNotEqual(UPSTREAM_PUBLIC_KEY, public_key)

    def test_non_sandboxed_app_uses_in_process_updater(self):
        info = plistlib.loads(INFO_PLIST.read_bytes())

        self.assertNotIn("SUEnableDownloaderService", info)
        self.assertNotIn("SUEnableInstallerLauncherService", info)

    def test_every_update_channel_uses_the_fork_feed(self):
        source = UPDATE_CHANNEL.read_text()

        self.assertIn(FORK_FEED, source)
        self.assertNotIn("Ebullioscopic/Atoll/main/Updates", source)


class SigningMaterialTests(unittest.TestCase):
    def test_only_public_material_is_committed(self):
        for path in SIGNING_DIR.rglob("*"):
            if path.is_file():
                self.assertNotIn("PRIVATE KEY", path.read_text(errors="ignore"), path)

    def test_certificate_is_a_code_signing_certificate(self):
        self.assertIn("BEGIN CERTIFICATE", CERTIFICATE.read_text())
        openssl = shutil.which("openssl")
        if openssl is None:
            self.skipTest("openssl is unavailable")

        text = subprocess.run(
            [openssl, "x509", "-in", str(CERTIFICATE), "-noout", "-text"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("Code Signing", text)
        self.assertIn("Atoll Fork Code Signing", text)


class ReleaseDecisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = load_release_module()

    def decide(self, previous, fork="f1", upstream="u2", force=False, changed=None):
        return self.release.decide(previous, fork, upstream, force, changed)[0]

    def test_first_release_is_published(self):
        self.assertTrue(self.decide(None))

    def test_force_always_publishes(self):
        previous = {"fork_sha": "f1", "upstream_sha": "u2"}
        self.assertTrue(self.decide(previous, force=True))

    def test_unchanged_inputs_are_skipped(self):
        previous = {"fork_sha": "f1", "upstream_sha": "u2"}
        self.assertFalse(self.decide(previous))

    def test_fork_change_is_published(self):
        previous = {"fork_sha": "f0", "upstream_sha": "u2"}
        self.assertTrue(self.decide(previous))

    def test_upstream_data_refresh_alone_is_skipped(self):
        previous = {"fork_sha": "f1", "upstream_sha": "u1"}
        changed = ["DynamicIsland/managers/LLMUsage/pricing.json"]
        self.assertFalse(self.decide(previous, changed=changed))

    def test_upstream_code_change_is_published(self):
        previous = {"fork_sha": "f1", "upstream_sha": "u1"}
        changed = ["DynamicIsland/managers/LLMUsage/pricing.json", "DynamicIsland/ContentView.swift"]
        self.assertTrue(self.decide(previous, changed=changed))

    def test_unknown_previous_upstream_commit_is_published(self):
        previous = {"fork_sha": "f1", "upstream_sha": "gone"}
        self.assertTrue(self.decide(previous, changed=None))


class AppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = load_release_module()

    def render(self, **overrides):
        values = {
            "version": "2.3.3-bc.202609180300",
            "build": "202609180300",
            "url": "https://github.com/beichengCqh/Atoll/releases/download/bc-202609180300/Atoll.zip?a=1&b=2",
            "length": 123,
            "signature": "c2lnbmF0dXJl",
            "minimum_system": "15.0",
            "notes": "- fix <lyrics> & \"quotes\"",
            "pub_date": "Fri, 18 Sep 2026 03:00:00 GMT",
        }
        values.update(overrides)
        return ET.fromstring(self.release.render_appcast(**values))

    def test_single_item_carries_sparkle_fields(self):
        items = self.render().findall("./channel/item")
        self.assertEqual(1, len(items))
        item = items[0]

        self.assertEqual("202609180300", item.findtext(f"{SPARKLE}version"))
        self.assertEqual("2.3.3-bc.202609180300", item.findtext(f"{SPARKLE}shortVersionString"))
        self.assertEqual("15.0", item.findtext(f"{SPARKLE}minimumSystemVersion"))
        enclosure = item.find("enclosure")
        self.assertEqual("123", enclosure.get("length"))
        self.assertEqual("c2lnbmF0dXJl", enclosure.get(f"{SPARKLE}edSignature"))
        self.assertTrue(enclosure.get("url").endswith("Atoll.zip?a=1&b=2"))

    def test_notes_render_as_literal_text(self):
        # description 按 HTML 渲染，提交说明里的尖括号与 & 要转义成实体才会原样显示；
        # 转义后 "]]>" 也无法提前闭合 CDATA
        description = self.render(notes="- fix <lyrics> & ]]> done").find("./channel/item/description").text
        self.assertEqual("<pre>- fix &lt;lyrics&gt; &amp; ]]&gt; done</pre>", description)

    def test_cli_writes_appcast_and_build_info(self):
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            info = Path(directory) / "build-info.json"
            subprocess.run(
                [
                    "python3", str(RELEASE_SCRIPT), "appcast",
                    "--version", "1.0-bc.1", "--build", "1", "--url", "https://example.invalid/a.zip",
                    "--length", "1", "--signature", "c2ln", "--minimum-system", "15.0",
                    "--output", str(appcast),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "python3", str(RELEASE_SCRIPT), "build-info",
                    "--fork-sha", "f", "--upstream-sha", "u", "--build", "1",
                    "--version", "1.0-bc.1", "--tag", "bc-1", "--output", str(info),
                ],
                check=True,
            )
            self.assertEqual("1", ET.parse(appcast).getroot().findtext(f"./channel/item/{SPARKLE}version"))
            self.assertIn('"upstream_sha": "u"', info.read_text())


class KeyToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("swiftc is unavailable")
        cls.directory = tempfile.TemporaryDirectory()
        cls.tool = Path(cls.directory.name) / "sparkle_key_tool"
        subprocess.run(["swiftc", "-o", str(cls.tool), str(KEY_TOOL)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_tool(self, *arguments, check=True):
        return subprocess.run([str(self.tool), *arguments], check=check, capture_output=True, text=True)

    def test_signature_round_trip_and_tamper_detection(self):
        keys = Path(self.directory.name) / "keys"
        public_key = self.run_tool("generate", str(keys)).stdout.strip()
        private_key = keys / "sparkle_private_key"
        self.assertEqual(public_key, self.run_tool("public", str(private_key)).stdout.strip())
        self.assertEqual(0o600, private_key.stat().st_mode & 0o777)

        archive = Path(self.directory.name) / "update.zip"
        archive.write_bytes(b"atoll update payload")
        signature = self.run_tool("sign", str(private_key), str(archive)).stdout.strip()
        self.assertEqual("OK", self.run_tool("verify", public_key, str(archive), signature).stdout.strip())

        archive.write_bytes(b"tampered payload")
        self.assertNotEqual(0, self.run_tool("verify", public_key, str(archive), signature, check=False).returncode)


class WorkflowTests(unittest.TestCase):
    def test_release_workflow_keeps_the_signing_contract(self):
        workflow = WORKFLOW.read_text()

        for fragment in (
            "github.repository == 'beichengCqh/Atoll'",
            "UPSTREAM_URL: https://github.com/Ebullioscopic/Atoll.git",
            "secrets.SPARKLE_ED_PRIVATE_KEY",
            "secrets.CODESIGN_PRIVATE_KEY",
            "--preserve-metadata=entitlements",
            "add-trusted-cert",
            "sign_update",
            'verify "$(/usr/libexec/PlistBuddy',
            "scripts/fork_release.py decide",
            "--draft",
            "--draft=false --latest",
            "tests/test_*.py",
        ):
            self.assertIn(fragment, workflow)

        # 沿用 ad-hoc 的 requirements 会把指定要求钉死在 cdhash 上，每次更新后系统权限都会失效
        for preserved in re.findall(r"--preserve-metadata=([\w,-]+)", workflow):
            self.assertNotIn("requirements", preserved)

    def test_new_python_files_are_tracked(self):
        gitignore = GITIGNORE.read_text()
        self.assertIn("!tests/test_fork_release.py", gitignore)
        self.assertIn("!scripts/fork_release.py", gitignore)


if __name__ == "__main__":
    unittest.main()
