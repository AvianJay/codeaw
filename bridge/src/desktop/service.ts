import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { bridgeInvocation } from "./process.js";
import { controlAddress, runningStatus } from "./control.js";
import { SERVICE_HOST, SERVICE_INSTALL_SCRIPT } from "./windows-service.js";

export function serviceName(file: string): string {
  const absolute = path.resolve(file);
  return "codeaw-bridge-" + crypto.createHash("sha256").update(process.platform === "win32" ? absolute.toLowerCase() : absolute).digest("hex").slice(0, 8);
}

export function quoteWindowsArgument(value: string): string {
  return '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"';
}

function run(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", windowsHide: true });
    child.once("error", reject);
    child.once("exit", (code) => code === 0 ? resolve() : reject(new Error(`${command} failed (${code})`)));
  });
}

export function systemdUnit(file: string, invocation = bridgeInvocation()): string {
  const quote = (value: string, expandDollar = false) => '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/%/g, "%%")
    .replace(/\$/g, () => expandDollar ? "$$" : "$").replace(/\n/g, "\\n") + '"';
  const args = [invocation.executable, ...invocation.args, "start", "--headless", "--config", file];
  return `[Unit]\nDescription=codeaw bridge\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=${args.map((arg) => quote(arg, true)).join(" ")}\nWorkingDirectory=${quote(path.dirname(file))}\nEnvironment=${quote(`PATH=${process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin"}`)}\nRestart=on-failure\nRestartSec=10\nTimeoutStopSec=15\nUMask=0077\n\n[Install]\nWantedBy=default.target\n`;
}

export function launchdPlist(file: string, name: string, invocation = bridgeInvocation()): string {
  const xml = (value: string) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const args = [invocation.executable, ...invocation.args, "start", "--headless", "--config", file];
  const log = path.join(path.dirname(file), "bridge.log");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>${xml(name)}</string>\n<key>ProgramArguments</key><array>${args.map((a) => `<string>${xml(a)}</string>`).join("")}</array>\n<key>WorkingDirectory</key><string>${xml(path.dirname(file))}</string>\n<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin")}</string></dict>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n<key>ThrottleInterval</key><integer>10</integer>\n<key>StandardOutPath</key><string>${xml(log)}</string>\n<key>StandardErrorPath</key><string>${xml(log)}</string>\n</dict></plist>\n`;
}

export async function manageService(file: string, action: string): Promise<void> {
  if (!["install", "uninstall", "start", "stop", "restart", "status"].includes(action)) {
    throw new Error("Usage: codeaw-bridge service <install|uninstall|start|stop|restart|status>");
  }
  const name = serviceName(file);
  if (process.platform === "win32") {
    if (action === "install") {
      const check = spawnSync("powershell.exe", ["-NoProfile", "-Command",
        "if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 1 }"], { windowsHide: true, stdio: "ignore" });
      if (check.status !== 0) throw new Error("Run service install in an administrator terminal. The service will use your normal Windows account.");
      if (await runningStatus(file)) throw new Error("Stop the existing bridge before installing the Windows service");
      const installed = spawnSync("sc.exe", ["query", name], { windowsHide: true, stdio: "ignore" });
      if (installed.status === 0) throw new Error("Service already installed. Uninstall it before updating the service host.");
      const directory = path.join(path.dirname(file), "runtime", name);
      fs.mkdirSync(directory, { recursive: true });
      const source = path.join(directory, "host.cs");
      const host = path.join(directory, "host.exe");
      const manifest = path.join(directory, "service.json");
      const installer = path.join(directory, "install.ps1");
      fs.writeFileSync(source, SERVICE_HOST);
      const framework = path.join(process.env.SystemRoot ?? "C:\\Windows", "Microsoft.NET",
        process.arch === "ia32" ? "Framework" : "Framework64", "v4.0.30319");
      await run(path.join(framework, "csc.exe"), ["/nologo", "/target:exe", "/reference:System.ServiceProcess.dll",
        "/reference:System.Web.Extensions.dll", `/out:${host}`, source]);
      const invocation = bridgeInvocation();
      const environment = Object.fromEntries(["PATH", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOME", "CODEAW_HOME"]
        .flatMap((key) => process.env[key] ? [[key, process.env[key]]] : []));
      fs.writeFileSync(manifest, JSON.stringify({ name, executable: invocation.executable,
        arguments: [...invocation.args, "start", "--headless", "--config", file].map(quoteWindowsArgument).join(" "),
        directory: path.dirname(file), logFile: path.join(path.dirname(file), "bridge.log"),
        pipeName: controlAddress(file).replace(/^\\\\\.\\pipe\\/, ""), environment }, null, 2));
      fs.writeFileSync(installer, "\ufeff" + SERVICE_INSTALL_SCRIPT);
      await run("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", installer,
        "-ManifestFile", manifest, "-HostFile", host, "-Account", `${process.env.USERDOMAIN}\\${process.env.USERNAME}`]);
      return;
    }
    const literal = name.replace(/'/g, "''");
    if (action === "uninstall") {
      await run("powershell.exe", ["-NoProfile", "-Command", `$ErrorActionPreference='Stop'; $s=Get-Service -Name '${literal}' -ErrorAction SilentlyContinue; if ($s) { Stop-Service -Name '${literal}' -Force; & sc.exe delete '${literal}'; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }`]);
    } else if (action === "status") await run("sc.exe", ["query", name]);
    else {
      const cmdlet = { start: "Start-Service", stop: "Stop-Service", restart: "Restart-Service" }[action];
      await run("powershell.exe", ["-NoProfile", "-Command", `$ErrorActionPreference='Stop'; ${cmdlet} -Name '${literal}'`]);
    }
  } else if (process.platform === "linux") {
    const unit = `${name}.service`;
    const target = path.join(os.homedir(), ".config", "systemd", "user", unit);
    if (action === "install") {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, systemdUnit(file), { mode: 0o600 });
      await run("systemctl", ["--user", "daemon-reload"]);
      await run("systemctl", ["--user", "enable", unit]);
    } else if (action === "uninstall") {
      await run("systemctl", ["--user", "disable", "--now", unit]);
      fs.rmSync(target, { force: true });
      await run("systemctl", ["--user", "daemon-reload"]);
    } else await run("systemctl", ["--user", action, unit]);
  } else if (process.platform === "darwin") {
    const label = `tw.codeaw.${name}`;
    const domain = `gui/${process.getuid!()}`;
    const target = path.join(os.homedir(), "Library", "LaunchAgents", `${label}.plist`);
    if (action === "install") {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, launchdPlist(file, label), { mode: 0o600 });
    } else if (action === "uninstall") {
      const result = spawnSync("launchctl", ["bootout", `${domain}/${label}`], { stdio: "ignore" });
      if (result.error) throw result.error;
      fs.rmSync(target, { force: true });
    } else if (action === "start") await run("launchctl", ["bootstrap", domain, target]);
    else if (action === "stop") await run("launchctl", ["bootout", `${domain}/${label}`]);
    else if (action === "restart") await run("launchctl", ["kickstart", "-k", `${domain}/${label}`]);
    else await run("launchctl", ["print", `${domain}/${label}`]);
  } else throw new Error(`Service management is unsupported on ${process.platform}`);
  if (action === "install") process.stdout.write(`Installed ${name}. Run codeaw-bridge service start to start it.\n`);
}
