param([string]$Executable, [string]$Config)
$CommandLine = '"' + $Executable + '" start --background --tray --config "' + $Config + '"'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class CodeawJobProbe {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
  public int cb; public string reserved, desktop, title;
  public int x,y,xsize,ysize,xcount,ycount,fill,flags; public short show, reserved2;
  public IntPtr reserved3,input,output,error;
 }
 [StructLayout(LayoutKind.Sequential)] struct Info {public IntPtr process,thread;public int pid,tid;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string name);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup startup,out Info info);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool member);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
 [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job,uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static IntPtr job;
 static void Check(bool ok) {if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error());}
 public static void Start(string app,string command,string cwd) {
  job=CreateJobObject(IntPtr.Zero,null); if(job==IntPtr.Zero) throw new Win32Exception();
  var si=new Startup {cb=Marshal.SizeOf(typeof(Startup))}; Info pi;
  Check(CreateProcess(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,cwd,ref si,out pi));
  try {Check(AssignProcessToJobObject(job,pi.process));ResumeThread(pi.thread);
   if(WaitForSingleObject(pi.process,30000)!=0) throw new Exception("Test CLI timed out");
  } finally {CloseHandle(pi.thread);CloseHandle(pi.process);}
 }
 public static bool Member(int pid) {var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero) throw new Win32Exception();try {bool m;Check(IsProcessInJob(h,job,out m));return m;}finally {CloseHandle(h);}}
 public static void Stop() {if(job!=IntPtr.Zero) {Check(TerminateJobObject(job,99));CloseHandle(job);job=IntPtr.Zero;}}
}
'@
try {
 [CodeawJobProbe]::Start($Executable,$CommandLine,(Split-Path -Parent $Config))
 $before = (& $Executable status --config $Config) -join "`n"
 if ($before -notmatch 'PID (\d+)') { throw "Isolated bridge failed to start: $before" }
 $bridgePid = [int]$Matches[1]
 $member = [CodeawJobProbe]::Member($bridgePid)
$pattern = [Regex]::Escape((Join-Path (Split-Path -Parent $Config) "runtime/tray.ps1"))
$trays = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match $pattern })
if ($trays.Count -ne 1) { throw "Expected one isolated tray" }
$trayMember = [CodeawJobProbe]::Member([int]$trays[0].ProcessId)
 [CodeawJobProbe]::Stop()
 Start-Sleep -Seconds 2
 $survived = $null -ne (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)
 [PSCustomObject]@{ pid=$bridgePid; inheritedTestJob=$member; survivedJobTermination=$survived; trayPid=$trays[0].ProcessId; trayInheritedTestJob=$trayMember; traySurvived=$null -ne (Get-Process -Id $trays[0].ProcessId -ErrorAction SilentlyContinue); sessionId=(Get-Process -Id $PID).SessionId } | ConvertTo-Json -Compress
} finally {
 [CodeawJobProbe]::Stop()
 & $Executable stop --config $Config | Out-Null
}
