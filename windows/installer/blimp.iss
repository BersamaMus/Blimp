; Blimp's Windows installer (Inno Setup). Build it with build_installer.ps1,
; which builds the app first and passes in the version from pubspec.yaml.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Identifies Blimp to Windows across versions, so updates replace it. Never
; change it.
AppId={{F6B5CA3D-C1D6-43EE-8494-EEB7F8CC522B}
AppName=Blimp
AppVersion={#AppVersion}
AppVerName=Blimp {#AppVersion}
AppPublisher=Blimp
DefaultDirName={autopf}\Blimp
DefaultGroupName=Blimp
DisableProgramGroupPage=yes
; Installs for just this user without asking for admin, unless they choose
; everyone.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=Blimp-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\blimp.exe
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
; Closes a running Blimp before updating it.
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Everything the release build needs beside blimp.exe: Flutter, the plugins'
; DLLs and the app's data folder.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Blimp"; Filename: "{app}\blimp.exe"
Name: "{autodesktop}\Blimp"; Filename: "{app}\blimp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\blimp.exe"; Description: "{cm:LaunchProgram,Blimp}"; Flags: nowait postinstall skipifsilent
