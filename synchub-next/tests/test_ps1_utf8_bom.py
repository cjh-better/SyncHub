"""Windows PowerShell 5.1 reads -File as ANSI unless the script has a UTF-8 BOM."""

import hashlib
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DISTRIBUTED = [
    ROOT / "scripts" / "build_app.ps1",
    ROOT / "scripts" / "install_windows.ps1",
    ROOT / "scripts" / "windows_single_tray.ps1",
    ROOT / "scripts" / "p0_acceptance.ps1",
    ROOT / "scripts" / "strip_windows_jni.ps1",
    ROOT / "server" / "deploy" / "build_linux.ps1",
    ROOT / "tests" / "run_all_e2e.ps1",
]
BOM = b"\xef\xbb\xbf"


class Ps1EncodingTest(unittest.TestCase):
    def test_distributed_scripts_are_utf8_with_bom(self):
        for path in DISTRIBUTED:
            data = path.read_bytes()
            self.assertTrue(path.is_file(), path)
            self.assertTrue(data.startswith(BOM), f"{path} is missing a UTF-8 BOM")
            data[len(BOM) :].decode("utf-8")

    def test_windows_bundle_copies_tray_helper(self):
        text = (ROOT / "scripts" / "build_app.ps1").read_text(encoding="utf-8-sig")
        self.assertIn('windows_single_tray.ps1', text)
        self.assertIn("Windows bundle is missing", text)
        installer = (ROOT / "scripts" / "install_windows.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("windows_single_tray.ps1 must be next to install_windows.ps1", installer)
        self.assertIn("strip_windows_jni.ps1", text)

    def test_trial_uses_official_shutdown_pipe(self):
        text = (ROOT / "scripts" / "windows_single_tray.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(r"Global\SyncClipboard-Pipe-", text)
        self.assertIn("WriteLine('Shutdown')", text)
        self.assertIn("退出", text)
        self.assertIn("-Seconds 45", text)
        self.assertIn("-Seconds 180", text)
        self.assertNotIn("taskkill", text.lower())
        self.assertNotIn("--shutdown-previous", text)
        self.assertNotIn("Start-Sleep -Milliseconds 800", text)
        self.assertLess(text.index("function Request-OfficialExit"), text.index('op = "trial"'))

    def test_installer_quarantines_only_known_jni_files(self):
        text = (ROOT / "scripts" / "install_windows.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("dartjni.dll", text)
        self.assertIn("jvm.dll", text)
        self.assertIn("ReparsePoint", text)
        self.assertIn("-LiteralPath", text)
        self.assertIn("$QuarantineJniOnly", text)
        self.assertIn("$RestoreJni", text)
        self.assertIn("preservedOtherDlls", text)
        self.assertNotIn("*.dll", text)

    def test_windows_build_uses_repo_icon_without_a_fixed_hash_lock(self):
        text = (ROOT / "scripts" / "build_app.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("-AppIcon", text)
        self.assertIn("SYNCHUB_APP_ICON", text)
        self.assertIn("resources\\app_icon.ico", text)
        self.assertIn("will not substitute the system icon", text)
        self.assertIn("not an ICO", text)
        self.assertNotIn("does not match the original SyncHub icon", text)
        rc = (ROOT / "app" / "windows" / "runner" / "Runner.rc").read_text(encoding="utf-8")
        self.assertIn('IDI_APP_ICON            ICON                    "resources\\\\app_icon.ico"', rc)
        self.assertNotIn("IDI_APPLICATION", rc)
        for name in ("flutter_window.cpp", "win32_window.cpp"):
            cpp = (ROOT / "app" / "windows" / "runner" / name).read_text(encoding="utf-8")
            self.assertNotIn("IDI_APPLICATION", cpp)
            self.assertIn("IDI_APP_ICON", cpp)

    def test_committed_app_icon_is_the_original_project_ico(self):
        icon = ROOT / "app" / "windows" / "runner" / "resources" / "app_icon.ico"
        data = icon.read_bytes()
        self.assertEqual(len(data), 33772)
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            "c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8",
        )
        reserved, kind, count = struct.unpack_from("<HHH", data, 0)
        self.assertEqual(reserved, 0)
        self.assertEqual(kind, 1)
        self.assertGreaterEqual(count, 1)
        self.assertGreaterEqual(len(data), 6 + count * 16)
        for index in range(count):
            size, offset = struct.unpack_from("<II", data, 6 + index * 16 + 8)
            self.assertGreater(size, 0)
            self.assertGreaterEqual(offset, 6 + count * 16)
            self.assertLessEqual(offset + size, len(data))


if __name__ == "__main__":
    unittest.main()
