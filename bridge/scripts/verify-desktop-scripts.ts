import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { DESKTOP_INSTALL_SCRIPT } from "../src/remote-desktop/service.js";
import { TRAY_SCRIPT } from "../src/desktop/windows-tray.js";
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-script-check-"));
const installer = path.join(directory, "installer.ps1"), tray = path.join(directory, "tray.ps1"), validator = path.join(directory, "validate.ps1");
fs.writeFileSync(installer, "\ufeff" + DESKTOP_INSTALL_SCRIPT); fs.writeFileSync(tray, "\ufeff" + TRAY_SCRIPT);
fs.writeFileSync(validator, String.raw`param([string]$First,[string]$Second)
foreach ($scriptFile in @($First,$Second)) {
  $scriptTokens=$null; $scriptErrors=$null
  [System.Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$scriptTokens,[ref]$scriptErrors) | Out-Null
  if ($scriptErrors.Count) { $scriptErrors | ForEach-Object { [Console]::Error.WriteLine($_.ErrorId) }; exit 1 }
}
`);
try {
  await promisify(execFile)("powershell.exe", ["-NoProfile", "-NonInteractive", "-File", validator, "-First", installer, "-Second", tray], { windowsHide: true });
  process.stdout.write("Installer and tray PowerShell syntax passed\n");
} finally { for (const file of [installer, tray, validator]) fs.rmSync(file, { force: true }); fs.rmdirSync(directory); }
