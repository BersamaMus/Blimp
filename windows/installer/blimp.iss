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
; Blimp's single-instance mutex (windows/runner/main.cpp), so setup also finds
; it running in the background, in the tray.
AppMutex=Blimp.SingleInstance
; Explorer picks up Blimp in "Open with" straight away.
ChangesAssociations=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Everything the release build needs beside blimp.exe: Flutter, the plugins'
; DLLs and the app's data folder.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; "Open with Blimp" for songs. Blimp is offered, not made the default: Windows
; leaves that to the user (Settings > Apps > Default apps).
Root: HKA; Subkey: "Software\Classes\Blimp.AudioFile"; ValueType: string; ValueName: ""; ValueData: "Audio file"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Blimp.AudioFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\blimp.exe,0"
Root: HKA; Subkey: "Software\Classes\Blimp.AudioFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\blimp.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Blimp"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\blimp.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.mp3\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".mp3"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.flac\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".flac"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.m4a\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".m4a"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.aac\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".aac"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.alac\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".alac"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.ogg\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".ogg"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.oga\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".oga"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.opus\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".opus"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.wav\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".wav"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.wma\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".wma"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.aiff\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".aiff"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.aif\OpenWithProgids"; ValueType: string; ValueName: "Blimp.AudioFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\blimp.exe\SupportedTypes"; ValueType: string; ValueName: ".aif"; ValueData: ""

[Icons]
Name: "{autoprograms}\Blimp"; Filename: "{app}\blimp.exe"
Name: "{autodesktop}\Blimp"; Filename: "{app}\blimp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\blimp.exe"; Description: "{cm:LaunchProgram,Blimp}"; Flags: nowait postinstall skipifsilent
