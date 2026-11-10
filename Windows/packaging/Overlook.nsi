Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"
!ifndef APP_VERSION
  !error "Use Windows/build-installer.ps1 to supply build paths and version."
!endif
Name "Overlook"
OutFile "${INSTALLER_OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\Overlook"
InstallDirRegKey HKCU "Software\Overlook" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
ManifestDPIAware true
VIProductVersion "${FILE_VERSION}"
VIAddVersionKey "ProductName" "Overlook"
VIAddVersionKey "FileDescription" "Overlook Windows Setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Overlook contributors"
!define MUI_ICON "Overlook.ico"
!define MUI_UNICON "Overlook.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\app\Overlook.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE.MD"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
  SetRegView 64
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Overlook requires 64-bit Windows."
    Abort
  ${EndIf}
  FindWindow $0 "OverlookMainWindow"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Close Overlook before installing or updating."
    SetErrorLevel 1
    Abort
  ${EndIf}
FunctionEnd

Section "Overlook (required)" SEC_APP
  SectionIn RO
  SetOutPath "$INSTDIR\app"
  SetOverwrite on
  File /r "${PAYLOAD_DIR}\*"
  SetOutPath "$INSTDIR"
  File /oname=LICENSE.md "..\..\LICENSE.MD"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\Overlook.lnk" "$INSTDIR\app\Overlook.exe" "" "$INSTDIR\app\Overlook.exe" 0
  WriteRegStr HKCU "Software\Overlook" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "DisplayName" "Overlook"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "Publisher" "Overlook contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "DisplayIcon" "$INSTDIR\app\Overlook.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "NoRepair" 1
  ${GetSize} "$INSTDIR\app" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook" "EstimatedSize" $0
SectionEnd

Section /o "Desktop shortcut" SEC_DESKTOP
  CreateShortcut "$DESKTOP\Overlook.lnk" "$INSTDIR\app\Overlook.exe" "" "$INSTDIR\app\Overlook.exe" 0
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  FindWindow $0 "OverlookMainWindow"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Close Overlook before uninstalling."
    SetErrorLevel 1
    Abort
  ${EndIf}
FunctionEnd

Section "Uninstall"
  !include "${UNINSTALL_MANIFEST}"
  Delete "$SMPROGRAMS\Overlook.lnk"
  Delete "$DESKTOP\Overlook.lnk"
  Delete "$INSTDIR\LICENSE.md"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Overlook"
  DeleteRegValue HKCU "Software\Overlook" "InstallDir"
  DeleteRegKey /ifempty HKCU "Software\Overlook"
  ; Devices, certificate pins, logs, and Credential Manager entries are retained.
SectionEnd
