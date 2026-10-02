// Render the real WinForms windows against an isolated bridge; never install a service or autostart task.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import YAML from "yaml";
import { loadConfig } from "../src/config.js";
import { controlAddress } from "../src/desktop/control.js";
import { BridgeRuntime } from "../src/desktop/runtime.js";
import { TRAY_SCRIPT } from "../src/desktop/windows-tray.js";
import { SERVICE_HOST, SERVICE_INSTALL_SCRIPT } from "../src/desktop/windows-service.js";
import { setLogSilent } from "../src/util/log.js";

if (process.platform !== "win32") throw new Error("Desktop smoke requires Windows");
setLogSilent(true);
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-ui-smoke-"));
const output = path.resolve("dist", "desktop-smoke");
fs.mkdirSync(output, { recursive: true });
const file = path.join(home, "config.yaml");
fs.writeFileSync(file, YAML.stringify({ listen: { hosts: ["127.0.0.1"], port: 0 }, workspaces: ["D:\\projects"],
  agents: { claude: { name: "Claude Code", command: "unused" }, codex: { name: "Codex", command: "unused", enabled: false } } }));
const runtime = new BridgeRuntime(loadConfig(file));

async function run(command: string, args: string[]): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    const timeout = setTimeout(() => { child.kill(); reject(new Error("Desktop smoke timed out")); }, 30_000);
    child.once("error", (err) => { clearTimeout(timeout); reject(err); });
    child.once("exit", (code) => { clearTimeout(timeout); code === 0 ? resolve() : reject(new Error(output)); });
  });
}

try {
  await runtime.start();
  runtime.bridge!.devices.addDeviceWithToken("Test phone", "synthetic-smoke-token");
  const smoke = String.raw`
    function Capture-Window([string]$Name) {
        $bitmap = [System.Drawing.Bitmap]::new($script:window.Width, $script:window.Height)
        try { $script:window.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height)); $bitmap.Save((Join-Path $OutputDirectory ($Name + '.png'))) }
        finally { $bitmap.Dispose() }
    }
    function Capture-Menu {
        $menu.Show([System.Drawing.Point]::new(20, 20))
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(200)
        $menu.Refresh()
        $menu.Update()
        [System.Windows.Forms.Application]::DoEvents()
        if ($menu.Items[2].Text -ne '配對手機…' -or $menu.Items[3].Text -ne '設定…') { throw 'Chinese tray menu labels are corrupted' }
        $bitmap = [System.Drawing.Bitmap]::new($menu.Width, $menu.Height)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $paint = [System.Windows.Forms.PaintEventArgs]::new($graphics, [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height))
                $flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
                $menu.GetType().GetMethod('OnPaintBackground', $flags).Invoke($menu, @($paint)) | Out-Null
                $menu.GetType().GetMethod('OnPaint', $flags).Invoke($menu, @($paint)) | Out-Null
            } finally { $graphics.Dispose() }
            $bitmap.Save((Join-Path $OutputDirectory 'tray-menu.png'))
        }
        finally { $bitmap.Dispose(); $menu.Close() }
    }
    $script:step = 0
    $script:smoke = [System.Windows.Forms.Timer]::new()
    $script:smoke.Interval = 1200
    $script:smoke.Add_Tick({
        try {
            switch ($script:step) {
                0 { Capture-Menu; Show-Pair }
                1 { if (-not $script:qr.Image -or $script:pairCode.Text.Length -ne 9) { throw 'Pair window did not load' }; Capture-Window 'pair'; Show-Settings }
                2 { if ($script:agents.Items.Count -ne 2 -or $script:folders.Text -ne 'D:\projects') { throw 'Settings window did not load' }; Capture-Window 'settings'; Show-Devices }
                3 { if ($script:devices.Items.Count -ne 1) { throw 'Devices window did not load' }; Capture-Window 'devices'; [System.Windows.Forms.Application]::Exit() }
            }
            $script:step++
        } catch { [Console]::Error.WriteLine($_); $script:smokeFailed = $true; [System.Windows.Forms.Application]::Exit() }
    })
    $script:smoke.Start()
    [System.Windows.Forms.Application]::Run()
    $script:smoke.Dispose()
    if ($script:smokeFailed) { exit 1 }
`;
  const traySource = process.argv[2] ? fs.readFileSync(path.resolve(process.argv[2]), "utf8").replace(/^\ufeff/, "") : TRAY_SCRIPT;
  const script = traySource.replace("[string]$LogFile)", "[string]$LogFile, [string]$OutputDirectory)")
    .replace("[System.Windows.Forms.Application]::Run()", smoke)
    .replace("function Show-Error($ErrorRecord) {", "function Show-Error($ErrorRecord) { throw $ErrorRecord; #");
  const scriptFile = path.join(home, "smoke.ps1");
  fs.writeFileSync(scriptFile, "\ufeff" + script);
  const hostSource = path.join(home, "host.cs");
  fs.writeFileSync(hostSource, SERVICE_HOST);
  await run(path.join(process.env.SystemRoot ?? "C:\\Windows", "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"),
    ["/nologo", "/reference:System.ServiceProcess.dll", "/reference:System.Web.Extensions.dll", `/out:${path.join(home, "host.exe")}`, hostSource]);
  const installer = path.join(home, "install.ps1");
  fs.writeFileSync(installer, "\ufeff" + SERVICE_INSTALL_SCRIPT);
  // Syntax-check installer without evaluating it or opening a credential prompt.
  const check = path.join(home, "check.ps1");
  fs.writeFileSync(check, "param([string]$Installer)\n$errors=$null\n[System.Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$null, [ref]$errors) | Out-Null\nif ($errors.Count) { throw ($errors | Out-String) }\n");
  await run("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", check, "-Installer", installer]);
  await run("powershell.exe", ["-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", scriptFile,
    "-PipeName", controlAddress(file).replace(/^\\\\\.\\pipe\\/, ""), "-OutputDirectory", output]);
  for (const name of ["tray-menu", "pair", "settings", "devices"]) {
    if (!fs.existsSync(path.join(output, `${name}.png`))) throw new Error(`Missing ${name} screenshot`);
  }
  process.stdout.write(`Desktop windows rendered; service host compiled. Screenshots: ${output}\n`);
} finally {
  await runtime.stop();
  fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
