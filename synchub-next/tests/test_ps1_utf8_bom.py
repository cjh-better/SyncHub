"""Windows PowerShell 5.1 reads -File as ANSI unless the script has a UTF-8 BOM."""

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


if __name__ == "__main__":
    unittest.main()
