# -*- coding: utf-8 -*-
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"

!define APP_NAME "codeaw bridge"
!define APP_KEY "Software\codeaw\bridge"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\codeaw-bridge"

Name "${APP_NAME} ${APP_VERSION} (${ARCH})"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\codeaw-bridge"
InstallDirRegKey HKCU "${APP_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "FileVersion" "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "FileDescription" "codeaw bridge installer (${ARCH})"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright (C) 2026 AvianJay"

Var StartMenuFolder
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_LANGDLL_REGISTRY_ROOT HKCU
!define MUI_LANGDLL_REGISTRY_KEY "${APP_KEY}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "InstallerLanguage"
!define MUI_STARTMENUPAGE_REGISTRY_ROOT HKCU
!define MUI_STARTMENUPAGE_REGISTRY_KEY "${APP_KEY}"
!define MUI_STARTMENUPAGE_REGISTRY_VALUENAME "StartMenuFolder"
!define MUI_STARTMENUPAGE_DEFAULTFOLDER "codeaw bridge"
!define MUI_STARTMENUPAGE_NODISABLE
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchTray
!define MUI_FINISHPAGE_RUN_TEXT "$(LaunchText)"
!define MUI_WELCOMEPAGE_TEXT "$(WelcomeText)"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${REPO_DIR}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_STARTMENU Application $StartMenuFolder
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "TradChinese"

LangString WelcomeText ${LANG_ENGLISH} "Install codeaw bridge for your Windows account.$\r$\n$\r$\nTailscale and ACP agents must be installed separately. Settings and paired devices are kept in your user profile.$\r$\n$\r$\nUpdating will stop the running bridge and its active turns. If you installed a Windows service, remove it from an administrator terminal before updating."
LangString WelcomeText ${LANG_TRADCHINESE} "為目前 Windows 使用者安裝 codeaw bridge。$\r$\n$\r$\nTailscale 與 ACP agents 需另外安裝；設定與配對裝置保存在使用者資料夾。$\r$\n$\r$\n更新會停止 bridge 與執行中的回合。若已安裝 Windows 服務，更新前請先從管理員終端機移除服務。"
LangString LaunchText ${LANG_ENGLISH} "Launch codeaw bridge in the system tray"
LangString LaunchText ${LANG_TRADCHINESE} "啟動 codeaw bridge 系統匣"
LangString CoreName ${LANG_ENGLISH} "Bridge and Start Menu shortcuts (required)"
LangString CoreName ${LANG_TRADCHINESE} "Bridge 與開始選單捷徑（必要）"
LangString StartupName ${LANG_ENGLISH} "Start the tray when you sign in"
LangString StartupName ${LANG_TRADCHINESE} "登入時自動啟動系統匣"
LangString DesktopName ${LANG_ENGLISH} "Desktop shortcut"
LangString DesktopName ${LANG_TRADCHINESE} "桌面捷徑"
LangString CoreDescription ${LANG_ENGLISH} "Install the bridge, pairing/settings shortcuts and uninstaller."
LangString CoreDescription ${LANG_TRADCHINESE} "安裝 bridge、配對／設定捷徑與移除程式。"
LangString StartupDescription ${LANG_ENGLISH} "Enable the current user's login startup; this can also be changed from the tray."
LangString StartupDescription ${LANG_TRADCHINESE} "啟用目前使用者的登入自動啟動，也可從系統匣變更。"
LangString DesktopDescription ${LANG_ENGLISH} "Create a shortcut on your desktop."
LangString DesktopDescription ${LANG_TRADCHINESE} "在桌面建立捷徑。"
LangString ArchitectureError ${LANG_ENGLISH} "This installer requires Windows 10 or later on ${ARCH}. Download the installer for your PC's architecture."
LangString ArchitectureError ${LANG_TRADCHINESE} "此安裝包需要 ${ARCH} 架構的 Windows 10 或更新版本，請下載符合電腦架構的安裝包。"
LangString ServiceError ${LANG_ENGLISH} "A Windows service is registered for this bridge. Run codeaw-bridge service uninstall in an administrator terminal before updating or uninstalling; reinstall the service after the update."
LangString ServiceError ${LANG_TRADCHINESE} "此 bridge 已註冊 Windows 服務。更新或移除前，請先從管理員終端機執行 codeaw-bridge service uninstall；更新後可重新安裝服務。"
LangString StopError ${LANG_ENGLISH} "Cannot stop the running bridge. Close the bridge and retry."
LangString StopError ${LANG_TRADCHINESE} "無法停止執行中的 bridge，請關閉 bridge 後重試。"
LangString StartupError ${LANG_ENGLISH} "Bridge was installed, but login startup could not be enabled. Enable it from the tray menu."
LangString StartupError ${LANG_TRADCHINESE} "Bridge 已安裝，但無法啟用登入自動啟動，請從系統匣選單設定。"

Function .onInit
  SetShellVarContext current
  SetRegView 64
  !insertmacro MUI_LANGDLL_DISPLAY
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "$(ArchitectureError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  !if "${ARCH}" == "arm64"
    ${IfNot} ${IsNativeARM64}
  !else
    ${IfNot} ${IsNativeAMD64}
  !endif
    MessageBox MB_OK|MB_ICONSTOP "$(ArchitectureError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
FunctionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  !insertmacro MUI_UNGETLANGUAGE
FunctionEnd

; The CLI sends a graceful stop through its local pipe. Never force-kill unrelated processes.
!macro StopInstalledBridge Prefix
Function ${Prefix}StopInstalledBridge
  IfFileExists "$INSTDIR\codeaw-bridge.exe" 0 done
  nsExec::ExecToStack /TIMEOUT=15000 '"$INSTDIR\codeaw-bridge.exe" service status'
  Pop $0
  Pop $1
  ${If} $0 == "timeout"
  ${OrIf} $0 == "error"
    MessageBox MB_OK|MB_ICONSTOP "$(StopError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  ${If} $0 == 0
    MessageBox MB_OK|MB_ICONSTOP "$(ServiceError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  nsExec::ExecToStack /TIMEOUT=15000 '"$INSTDIR\codeaw-bridge.exe" stop'
  Pop $0
  Pop $1
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "$(StopError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  ; Let the desktop companion notice the closed pipe and release its resources.
  Sleep 500
  done:
FunctionEnd
!macroend
!insertmacro StopInstalledBridge ""
!insertmacro StopInstalledBridge "un."

Function LaunchTray
  Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\launch.ps1" -Page tray'
FunctionEnd

Section "$(CoreName)" Core
  SectionIn RO
  Call StopInstalledBridge
  SetOutPath "$INSTDIR"
  File /oname=codeaw-bridge.exe "${BRIDGE_EXE}"
  File /oname=launch.ps1 "${INSTALLER_DIR}\launch.ps1"
  File /oname=LICENSE "${REPO_DIR}\LICENSE"
  File /oname=README.md "${REPO_DIR}\README.md"
  !ifdef WEB_DIR
    SetOutPath "$INSTDIR\web"
    File /r "${WEB_DIR}\*"
    SetOutPath "$INSTDIR"
  !endif
  WriteUninstaller "$INSTDIR\uninstall.exe"
  !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    CreateDirectory "$SMPROGRAMS\$StartMenuFolder"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\codeaw bridge.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\launch.ps1" -Page tray' "$INSTDIR\codeaw-bridge.exe"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\Pair phone.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\launch.ps1" -Page pair' "$INSTDIR\codeaw-bridge.exe"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\Settings.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\launch.ps1" -Page settings' "$INSTDIR\codeaw-bridge.exe"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\Uninstall.lnk" "$INSTDIR\uninstall.exe"
  !insertmacro MUI_STARTMENU_WRITE_END
  WriteRegStr HKCU "${APP_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME} (${ARCH})"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "AvianJay"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\uninstall.exe$\" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\codeaw-bridge.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/AvianJay/codeaw"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" $0
SectionEnd

Section /o "$(StartupName)" Startup
  nsExec::ExecToStack /TIMEOUT=15000 '"$INSTDIR\codeaw-bridge.exe" autostart install'
  Pop $0
  Pop $1
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(StartupError)" /SD IDOK
  ${EndIf}
SectionEnd

Section /o "$(DesktopName)" Desktop
  CreateShortcut "$DESKTOP\codeaw bridge.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\launch.ps1" -Page tray' "$INSTDIR\codeaw-bridge.exe"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${Core} "$(CoreDescription)"
  !insertmacro MUI_DESCRIPTION_TEXT ${Startup} "$(StartupDescription)"
  !insertmacro MUI_DESCRIPTION_TEXT ${Desktop} "$(DesktopDescription)"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  Call un.StopInstalledBridge
  nsExec::ExecToStack /TIMEOUT=15000 '"$INSTDIR\codeaw-bridge.exe" autostart uninstall'
  Pop $0
  Pop $1
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "$(StopError)" /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  !insertmacro MUI_STARTMENU_GETFOLDER Application $StartMenuFolder
  Delete "$SMPROGRAMS\$StartMenuFolder\codeaw bridge.lnk"
  Delete "$SMPROGRAMS\$StartMenuFolder\Pair phone.lnk"
  Delete "$SMPROGRAMS\$StartMenuFolder\Settings.lnk"
  Delete "$SMPROGRAMS\$StartMenuFolder\Uninstall.lnk"
  RMDir "$SMPROGRAMS\$StartMenuFolder"
  Delete "$DESKTOP\codeaw bridge.lnk"
  Delete "$INSTDIR\codeaw-bridge.exe"
  Delete "$INSTDIR\launch.ps1"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\README.md"
  !ifdef WEB_DIR
    RMDir /r "$INSTDIR\web"
  !endif
  Delete "$INSTDIR\uninstall.exe"
  ; Remove only known application files, leaving custom files and ~/.codeaw intact.
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "${APP_KEY}"
SectionEnd
