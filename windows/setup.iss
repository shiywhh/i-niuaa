; i泥航 Windows 安装包
; Build: "D:\Inno Setup 6\ISCC.exe" setup.iss
; 输出: installer\nuaa_eams_1.1.0_setup.exe

#define MyAppName "i泥航"
#define MyAppVersion "2.4.0"
#define MyAppExeName "nuaa_eams.exe"
#define ReleaseDir "D:\jiaowu\nuaa_eams\build\windows\x64\runner\Release"

[Setup]
AppId={{8A1C93F7-52B4-4E77-9E1A-D3F60C25B119}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
DefaultDirName={autopf}\nuaa_eams
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=D:\jiaowu\nuaa_eams\installer
OutputBaseFilename=i-niuaa-{#MyAppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=admin

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; \
    Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent
