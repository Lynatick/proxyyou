#ifndef AppVersion
  #define AppVersion "4.1.24"
#endif
#ifndef BuildRoot
  #define BuildRoot "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId=dev.proxyyou.client.windows
AppName=ProxyYou
AppVersion={#AppVersion}
AppPublisher=ProxyYou
DefaultDirName={localappdata}\Programs\ProxyYou
DefaultGroupName=ProxyYou
UninstallDisplayIcon={app}\ProxyYou.exe
OutputDir=..\..\out
OutputBaseFilename=ProxyYou-Windows-x64-{#AppVersion}-Setup
SetupIconFile=..\runner\resources\app_icon.ico
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
LicenseFile=..\..\LICENSE.md

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; Flags: unchecked

[Files]
; Package runtime components explicitly; session caches stay outside the installer.
Source: "{#BuildRoot}\*.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildRoot}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildRoot}\LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildRoot}\WINDOWS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildRoot}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ProxyYou"; Filename: "{app}\ProxyYou.exe"
Name: "{autodesktop}\ProxyYou"; Filename: "{app}\ProxyYou.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ProxyYou.exe"; Description: "Запустить ProxyYou"; Flags: nowait postinstall skipifsilent
