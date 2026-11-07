<#
.SYNOPSIS
    Windows 一键构建：Flutter Release → staging → Inno Setup 安装包。

.DESCRIPTION
    对应 macOS 的 scripts/build_dmg.sh。三步流水线：

        1. flutter build windows --release
        2. python .data\prepare_staging.py   （前端 + backend + 便携运行时 + VC 运行库 → .data\staging）
        3. ISCC.exe .data\setup.iss          （产出 dist\GradeMonitor_Ver.x.y.z_setup.exe）

    runtime\tools（便携 Python）不存在时会自动调用 prepare_runtime_windows.ps1
    生成；已有则跳过（除非传 -RebuildRuntime）。

.PARAMETER SkipFlutter
    跳过第 1 步，直接用已有的 frontend\build\windows\x64\runner\Release。

.PARAMETER SkipInstaller
    只做到 staging，不调用 ISCC。

.PARAMETER RebuildRuntime
    强制重建 runtime\tools（会重新 pip install 后端依赖）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipFlutter,
    [switch]$SkipInstaller,
    [switch]$RebuildRuntime
)

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $Root '.data'
$Release = Join-Path $Root 'frontend\build\windows\x64\runner\Release'
$Tools   = Join-Path $Root 'runtime\tools'
$Iss     = Join-Path $DataDir 'setup.iss'
$DistDir = Join-Path $Root 'dist'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[  ok  ] $msg" -ForegroundColor Green }
function Fail($msg)       { Write-Host "[ FAIL ] $msg" -ForegroundColor Red; exit 1 }

function Resolve-Python {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $found = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $found) { return $found.Trim() }
        } catch { }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($pattern in @(
        "$env:ProgramFiles\Python*\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe"
    )) {
        $hit = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    Fail '未找到 Python 解释器（prepare_staging.py 需要它）'
}

# ---------- 版本号一致性检查 ----------
# 版本号有 3 处落点必须同步（见提交 45bf20e）：
#   frontend/pubspec.yaml            version: X.Y.Z+B
#   frontend/windows/runner/Runner.rc VERSION_AS_STRING "X.Y.Z.B"
#   .data/setup.iss                   AppVersion / VersionInfoVersion / 文件名
Write-Step '检查版本号三处落点一致性'
$pubspec = Join-Path $Root 'frontend\pubspec.yaml'
$runnerRc = Join-Path $Root 'frontend\windows\runner\Runner.rc'

$pubLine = Select-String -LiteralPath $pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $pubLine) { Fail "无法从 pubspec.yaml 读取版本号" }
$pubVersion = $pubLine.Matches[0].Groups[1].Value          # 例如 108.1.0+101
if ($pubVersion -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') {
    Fail "pubspec.yaml 版本号格式异常: $pubVersion（应为 X.Y.Z+B）"
}
$semver  = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$build   = $Matches[4]
$winVer  = "$semver.$build"                                 # 例如 108.1.0.101

$rcLine = Select-String -LiteralPath $runnerRc -Pattern 'VERSION_AS_STRING\s+"([^"]+)"' | Select-Object -First 1
if (-not $rcLine) { Fail 'Runner.rc 中找不到 VERSION_AS_STRING' }
$rcVersion = $rcLine.Matches[0].Groups[1].Value
if ($rcVersion -ne $winVer) {
    Fail "版本号不一致：pubspec.yaml=$pubVersion (exe 应为 $winVer)，Runner.rc=$rcVersion。`n请同步修改 frontend/windows/runner/Runner.rc 与 .data/setup.iss。"
}

$issText = Get-Content -LiteralPath $Iss -Raw -Encoding UTF8
if ($issText -notmatch [regex]::Escape("AppVersion=$winVer")) {
    Fail "setup.iss 的 AppVersion 未同步为 $winVer（pubspec.yaml 为 $pubVersion）"
}
Write-Ok "版本号一致: $winVer"

# ---------- 1. Flutter Release ----------
if ($SkipFlutter) {
    Write-Step '跳过 Flutter 构建（-SkipFlutter）'
} else {
    Write-Step 'flutter build windows --release'
    $flutter = Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
    if (-not $env:FLUTTER_ROOT -or -not (Test-Path -LiteralPath $flutter)) {
        $cmd = Get-Command flutter -ErrorAction SilentlyContinue
        if (-not $cmd) { Fail '未找到 flutter，请确保 Flutter SDK 在 PATH 中' }
        $flutter = $cmd.Source
    }
    Push-Location (Join-Path $Root 'frontend')
    try {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { Fail 'flutter build windows 失败' }
    } finally {
        Pop-Location
    }
}
if (-not (Test-Path -LiteralPath $Release)) { Fail "缺少构建产物: $Release" }
Write-Ok "前端 Release: $Release"

# ---------- 2. 便携运行时 ----------
$needRuntime = $RebuildRuntime -or (-not (Test-Path -LiteralPath (Join-Path $Tools 'python.exe')))
if ($needRuntime) {
    Write-Step '准备便携 Python 运行时'
    $runtimeScript = Join-Path $PSScriptRoot 'prepare_runtime_windows.ps1'
    if (-not (Test-Path -LiteralPath $runtimeScript)) { Fail "缺少脚本: $runtimeScript" }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runtimeScript)
    if ($RebuildRuntime) { $psArgs += '-Clean' }
    & powershell.exe @psArgs
    if ($LASTEXITCODE -ne 0) { Fail '便携运行时准备失败' }
} else {
    Write-Ok "便携运行时已存在: $Tools（-RebuildRuntime 可重建）"
}

# ---------- 3. staging ----------
Write-Step '准备 staging'
$python = Resolve-Python
& $python (Join-Path $DataDir 'prepare_staging.py')
if ($LASTEXITCODE -ne 0) { Fail 'prepare_staging.py 失败' }

# ---------- 4. Inno Setup ----------
if ($SkipInstaller) {
    Write-Step '跳过安装包构建（-SkipInstaller）'
} else {
    Write-Step '编译安装包'
    $iscc = $null
    foreach ($p in @(
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path -LiteralPath $p) { $iscc = $p; break }
    }
    if (-not $iscc) {
        $cmd = Get-Command ISCC -ErrorAction SilentlyContinue
        if ($cmd) { $iscc = $cmd.Source }
    }
    if (-not $iscc) { Fail '未找到 Inno Setup 6 的 ISCC.exe，请先安装 Inno Setup 6' }

    & $iscc $Iss
    if ($LASTEXITCODE -ne 0) { Fail 'ISCC 编译失败' }

    $expected = Join-Path $DistDir ("GradeMonitor_Ver.{0}_setup.exe" -f $winVer)
    if (Test-Path -LiteralPath $expected) {
        $mb = (Get-Item -LiteralPath $expected).Length / 1MB
        Write-Ok ("安装包: {0} ({1:N1} MB)" -f $expected, $mb)
    } else {
        Write-Ok "安装包输出目录: $DistDir"
    }
}

Write-Host ''
Write-Ok 'Windows 构建完成'
