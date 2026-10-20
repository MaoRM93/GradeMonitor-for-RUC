; GradeMonitor 安装脚本 (Inno Setup)
; 小白用户：双击 setup.exe → 一路下一步 → 完成即可使用

[Setup]
AppId={{7B8A9C0D-1E2F-3A4B-5C6D-7E8F9A0B1C2D}
AppName=GradeMonitor
AppVersion=108.0.0.100
AppPublisher=GradeMonitor
AppVerName=GradeMonitor Ver.108.0.0.100
VersionInfoVersion=108.0.0.100
VersionInfoProductVersion=108.0.0.100
VersionInfoProductName=GradeMonitor
VersionInfoCompany=GradeMonitor
DefaultDirName={localappdata}\Programs\GradeMonitor
DefaultGroupName=GradeMonitor
DisableProgramGroupPage=yes
OutputDir=C:\Projects\GradeMonitor8\dist
OutputBaseFilename=GradeMonitor_Ver.108.0.0.100_setup
SetupIconFile=C:\Projects\GradeMonitor8\frontend\assets\app_icon.ico
UninstallDisplayIcon={app}\grademonitor.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
; 保持 per-user 安装，覆盖旧版到同一 %LOCALAPPDATA% 目录，避免管理员模式产生重复卸载项。
; 覆盖失败的真实原因是旧进程锁住 flutter_windows.dll，[Code] 会在复制前关闭旧版。
PrivilegesRequired=lowest
CloseApplications=force
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "C:\Projects\GradeMonitor8\.data\staging\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[InstallDelete]
; 旧版快捷方式可能缓存了旧的 exe 图标，先删除再由 [Icons] 重建。
Type: files; Name: "{autodesktop}\GradeMonitor.lnk"
Type: files; Name: "{autoprograms}\GradeMonitor.lnk"

[Icons]
Name: "{autodesktop}\GradeMonitor"; Filename: "{app}\grademonitor.exe"; WorkingDir: "{app}"; IconFilename: "{app}\grademonitor.exe"; IconIndex: 0
Name: "{autoprograms}\GradeMonitor"; Filename: "{app}\grademonitor.exe"; WorkingDir: "{app}"; IconFilename: "{app}\grademonitor.exe"; IconIndex: 0
Name: "{autoprograms}\卸载 GradeMonitor"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\grademonitor.exe"; Description: "立即运行 GradeMonitor"; Flags: nowait postinstall skipifsilent

[Code]
procedure SHChangeNotify(wEventId: Longint; uFlags: Cardinal;
  dwItem1, dwItem2: Longint);
  external 'SHChangeNotify@shell32.dll stdcall';

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // 通知 Shell 刷新图标，避免升级后快捷方式继续显示旧图标。
  if CurStep = ssPostInstall then
    SHChangeNotify($08000000, $0000, 0, 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  // 先请求旧版正常退出，给应用机会清理后台进程。
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM grademonitor.exe', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1000);
  // 若旧版仍驻留托盘，强制结束，释放 flutter_windows.dll 等文件句柄。
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM grademonitor.exe', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;
