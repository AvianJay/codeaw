/** .NET Framework ships with Windows; this small SCM host supervises the existing bridge runtime. */
export const SERVICE_HOST = String.raw`
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public class Manifest {
    public string name { get; set; }
    public string executable { get; set; }
    public string arguments { get; set; }
    public string directory { get; set; }
    public string logFile { get; set; }
    public string pipeName { get; set; }
    public Dictionary<string, string> environment { get; set; }
}

public class BridgeService : ServiceBase {
    private readonly Manifest config;
    private Process child;
    private StreamWriter log;
    private volatile bool stopping;
    private readonly object logLock = new object();

    public BridgeService(Manifest manifest) {
        config = manifest;
        ServiceName = manifest.name;
        CanShutdown = true;
        AutoLog = true;
    }

    private void WriteLog(object sender, DataReceivedEventArgs args) {
        if (args.Data == null) return;
        lock (logLock) { if (log != null) { log.WriteLine(args.Data); log.Flush(); } }
    }

    private string Control(string command) {
        using (var pipe = new NamedPipeClientStream(".", config.pipeName, PipeDirection.InOut)) {
            pipe.Connect(1000);
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true))
            using (var reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, true)) {
                writer.WriteLine("{\"command\":\"" + command + "\"}"); writer.Flush();
                var task = reader.ReadLineAsync();
                if (!task.Wait(3000)) throw new System.TimeoutException();
                return task.Result;
            }
        }
    }

    protected override void OnStart(string[] args) {
        stopping = false;
        Directory.CreateDirectory(config.directory);
        if (File.Exists(config.logFile) && new FileInfo(config.logFile).Length > 5 * 1024 * 1024) {
            if (File.Exists(config.logFile + ".1")) File.Delete(config.logFile + ".1");
            File.Move(config.logFile, config.logFile + ".1");
        }
        log = new StreamWriter(new FileStream(config.logFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        var start = new ProcessStartInfo(config.executable, config.arguments);
        start.WorkingDirectory = config.directory;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        foreach (var item in config.environment) start.EnvironmentVariables[item.Key] = item.Value;
        child = new Process(); child.StartInfo = start;
        child.OutputDataReceived += WriteLog;
        child.ErrorDataReceived += WriteLog;
        child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
        RequestAdditionalTime(20000);
        bool ready = false;
        for (int i = 0; i < 60; i++) {
            if (child.HasExited) break;
            try {
                var response = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Control("status"));
                var result = response["result"] as Dictionary<string, object>;
                if (result != null && Convert.ToInt32(result["pid"]) == child.Id && (string)result["state"] == "running") { ready = true; break; }
            } catch { }
            Thread.Sleep(100);
        }
        if (!ready) {
            stopping = true;
            KillChild();
            lock (logLock) { log.Dispose(); log = null; }
            throw new InvalidOperationException("Bridge failed to start; see bridge.log");
        }
        child.EnableRaisingEvents = true;
        child.Exited += delegate {
            if (stopping) return;
            if (child.ExitCode == 0) Stop();
            else Environment.Exit(1); // Unexpected failure triggers SCM recovery.
        };
        if (child.HasExited) { if (child.ExitCode == 0) Stop(); else Environment.Exit(1); }
    }

    private void KillChild() {
        if (child == null || child.HasExited) return;
        var kill = new ProcessStartInfo("taskkill.exe", "/PID " + child.Id + " /T /F");
        kill.UseShellExecute = false; kill.CreateNoWindow = true;
        kill.RedirectStandardOutput = true; kill.RedirectStandardError = true;
        using (var process = Process.Start(kill)) { process.WaitForExit(5000); }
    }

    protected override void OnStop() {
        stopping = true;
        RequestAdditionalTime(15000);
        try { Control("stop"); } catch { }
        if (child != null) { if (!child.WaitForExit(10000)) KillChild(); child.Dispose(); child = null; }
        lock (logLock) { if (log != null) { log.Dispose(); log = null; } }
    }
    protected override void OnShutdown() { OnStop(); }

    public static void Main(string[] args) {
        if (args.Length != 1) throw new ArgumentException("Expected service manifest path");
        var manifest = new JavaScriptSerializer().Deserialize<Manifest>(File.ReadAllText(args[0]));
        ServiceBase.Run(new BridgeService(manifest));
    }
}
`;

export const SERVICE_INSTALL_SCRIPT = String.raw`
param([string]$ManifestFile, [string]$HostFile, [string]$Account)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess
Add-Type -AssemblyName System.Configuration.Install
$manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
if (Get-Service -Name $manifest.name -ErrorAction SilentlyContinue) { throw 'Service already installed. Uninstall it before updating the service host.' }
$credential = Get-Credential -UserName $Account -Message 'Run codeaw bridge as your normal Windows account (enter account password, not Windows Hello PIN).'
if (-not $credential) { throw 'Service installation cancelled' }
$expected = ([System.Security.Principal.NTAccount]::new($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$actual = ([System.Security.Principal.NTAccount]::new($credential.UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
if ($actual -ne $expected) { throw 'Use the same Windows account as your bridge config and agents' }
$installer = [System.Configuration.Install.TransactedInstaller]::new()
$context = [System.Configuration.Install.InstallContext]::new()
$context.Parameters['assemblypath'] = '"' + $HostFile + '" "' + $ManifestFile + '"'
$context.Parameters['logtoconsole'] = 'false'
$context.Parameters['logfile'] = ''
$installer.Context = $context
$process = [System.ServiceProcess.ServiceProcessInstaller]::new()
$process.Account = [System.ServiceProcess.ServiceAccount]::User
$process.Username = $credential.UserName
$process.Password = $credential.GetNetworkCredential().Password
$service = [System.ServiceProcess.ServiceInstaller]::new()
$service.ServiceName = $manifest.name
$service.DisplayName = 'codeaw bridge (' + $manifest.name + ')'
$service.Description = 'Background ACP bridge over Tailscale'
$service.StartType = [System.ServiceProcess.ServiceStartMode]::Automatic
$installer.Installers.Add($process) | Out-Null
$installer.Installers.Add($service) | Out-Null
try { $installer.Install(@{}) } finally { $process.Password = $null; $credential = $null; $installer.Dispose() }
& sc.exe failure $manifest.name reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Service installed, but recovery configuration failed' }
& sc.exe config $manifest.name start= delayed-auto | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Service installed, but delayed start configuration failed' }
Write-Output ('Installed ' + $manifest.name + '. Start it with codeaw-bridge service start.')
`;
