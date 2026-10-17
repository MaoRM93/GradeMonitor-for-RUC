; GradeMonitor 安装脚本 (Inno Setup)
; 小白用户：双击 setup.exe → 一路下一步 → 完成即可使用

[Setup]
AppId={{7B8A9C0D-1E2F-3A4B-5C6D-7E8F9A0B1C2D}
AppName=GradeMonitor
AppVersion=107.0.0.115
AppPublisher=GradeMonitor
AppVerName=GradeMonitor Ver.107.0.0.115
DefaultDirName={localappdata}\Programs\GradeMonitor
DefaultGroupName=GradeMonitor
DisableProgramGroupPage=yes
OutputDir=D:\Projects\GradeDetector_Windows_4\dist
OutputBaseFilename=GradeMonitor_Ver.107.0.0.115_setup
SetupIconFile=D:\Projects\GradeDetector_Windows_4\frontend\assets\app_icon.ico
UninstallDisplayIcon={app}\grademonitor.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "D:\Projects\GradeDetector_Windows_4\.data\staging\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{autodesktop}\GradeMonitor"; Filename: "{app}\grademonitor.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\GradeMonitor"; Filename: "{app}\grademonitor.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\卸载 GradeMonitor"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\grademonitor.exe"; Description: "立即运行 GradeMonitor"; Flags: nowait postinstall skipifsilent
