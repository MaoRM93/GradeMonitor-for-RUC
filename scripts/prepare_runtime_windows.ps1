<#
.SYNOPSIS
    为 Windows 打包准备便携 Python 运行时（runtime\tools）。

.DESCRIPTION
    仓库里 macOS 侧有 scripts/inject_backend_macos.sh 把「便携 Python +
    backend」塞进 .app；Windows 侧原先只靠 .data/prepare_staging.py 复制
    runtime\tools，却没有人生成这个目录，于是打不出可用安装包。

    本脚本补上这一环，产出一个**不依赖用户机器上任何 Python 安装**的
    独立运行时：

        runtime\tools\python.exe          <- 前端 BackendService._findPython() 的候选路径
        runtime\tools\Lib\site-packages   <- 后端依赖装在这里
        runtime\tools\DLLs, libs, ...

    做法：把本机基础解释器的运行时文件复制过来（排除 site-packages 与
    测试/教学模块），再用**基础解释器的 pip** 把后端依赖 --target 到复制体
    的 site-packages。之所以不直接 `python -m venv`：venv 的 python.exe 通过
    pyvenv.cfg 的 home= 指回本机路径，换到用户机器就失效，无法便携。

.PARAMETER Python
    基础解释器路径。默认依次尝试 py -3、python、C:\Program Files\Python*\python.exe。

.PARAMETER Clean
    先清空 runtime\tools 再重建。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_runtime_windows.ps1 -Clean
#>
[CmdletBinding()]
param(
    [string]$Python = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$Tools    = Join-Path $Root 'runtime\tools'
$Reqs     = Join-Path $Root 'backend\requirements.txt'
$SitePkgs = Join-Path $Tools 'Lib\site-packages'

function Write-Step($msg)  { Write-Host "[runtime] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[  ok  ] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[ warn ] $msg" -ForegroundColor Yellow }
function Fail($msg)        { Write-Host "[ FAIL ] $msg" -ForegroundColor Red; exit 1 }

# ---------- 1. 定位基础解释器 ----------
function Resolve-BasePython {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { Fail "指定的解释器不存在: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $candidates = New-Object System.Collections.ArrayList
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $found = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $found) { [void]$candidates.Add($found.Trim()) }
        } catch { }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }

    foreach ($pattern in @(
        "$env:ProgramFiles\Python*\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe"
    )) {
        Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object { [void]$candidates.Add($_.FullName) }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        # 必须能真正执行（WindowsApps 下的 python.exe 是商店占位符，会失败）
        try {
            $v = & $c -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) { return (Resolve-Path -LiteralPath $c).Path }
        } catch { }
    }
    Fail '未找到可用的 Python 解释器。请安装 Python 3.10+ 或用 -Python 显式指定。'
}

$basePython = Resolve-BasePython -Explicit $Python
$baseDir    = Split-Path -Parent $basePython
$pyVersion  = (& $basePython -c "import sys; print('%d.%d.%d' % sys.version_info[:3])").Trim()
Write-Step "基础解释器: $basePython (Python $pyVersion)"

if ($pyVersion -match '^(\d+)\.(\d+)') {
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
        Fail "需要 Python 3.10+，当前为 $pyVersion"
    }
}
if (-not (Test-Path -LiteralPath $Reqs)) { Fail "缺少依赖清单: $Reqs" }

# 基础解释器必须自带 pip（我们用它往复制体里装依赖）
$pipCheck = & $basePython -m pip --version 2>&1
if ($LASTEXITCODE -ne 0) { Fail "基础解释器缺少 pip:`n$pipCheck" }

# ---------- 2. 重建目录 ----------
if (Test-Path -LiteralPath $Tools) {
    if ($Clean) {
        Write-Step '清理旧的 runtime\tools'
        Remove-Item -LiteralPath $Tools -Recurse -Force
    } else {
        Write-Warn2 'runtime\tools 已存在，增量覆盖（加 -Clean 可彻底重建）'
    }
}
New-Item -ItemType Directory -Force -Path $Tools | Out-Null
New-Item -ItemType Directory -Force -Path $SitePkgs | Out-Null

# ---------- 3. 复制解释器运行时 ----------
Write-Step '复制解释器运行时到 runtime\tools'
$skipDirs = @(
    'site-packages', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo',
    'ensurepip', 'lib2to3', 'pydoc_data', 'include', '__pycache__'
)

# 顶层文件：python.exe / pythonw.exe / python3*.dll / vcruntime*.dll
Get-ChildItem -LiteralPath $baseDir -File | Where-Object {
    $_.Name -match '^(python(w)?\.exe|python3.*\.dll|vcruntime.*\.dll|python.*\.dll)$'
} | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Tools $_.Name) -Force
}

# DLLs\（标准扩展模块，必须原样带）
$srcDlls = Join-Path $baseDir 'DLLs'
if (Test-Path -LiteralPath $srcDlls) {
    Copy-Item -LiteralPath $srcDlls -Destination (Join-Path $Tools 'DLLs') -Recurse -Force
}
# libs\（导入库，体积小，保留以便个别包做编译探测）
$srcLibs = Join-Path $baseDir 'libs'
if (Test-Path -LiteralPath $srcLibs) {
    Copy-Item -LiteralPath $srcLibs -Destination (Join-Path $Tools 'libs') -Recurse -Force
}

# Lib\ 逐个子项复制，跳过 site-packages 与测试/教学模块
$srcLib = Join-Path $baseDir 'Lib'
if (-not (Test-Path -LiteralPath $srcLib)) { Fail "基础解释器缺少 Lib 目录: $srcLib" }
New-Item -ItemType Directory -Force -Path (Join-Path $Tools 'Lib') | Out-Null
Get-ChildItem -LiteralPath $srcLib | Where-Object { $skipDirs -notcontains $_.Name } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $Tools 'Lib') $_.Name) -Recurse -Force
}

# ---------- 4. 冒烟测试：复制体可独立运行 ----------
$portable = Join-Path $Tools 'python.exe'
if (-not (Test-Path -LiteralPath $portable)) { Fail "复制后缺少 python.exe: $portable" }
$smoke = & $portable -c "import sys, json, ssl, sqlite3, ctypes; print(sys.version.split()[0])" 2>&1
if ($LASTEXITCODE -ne 0) { Fail "复制体无法运行:`n$smoke" }
Write-Ok "便携解释器可用 (Python $($smoke -join ''))"

# ---------- 5. 安装后端依赖 ----------
Write-Step '安装后端依赖到 runtime\tools\Lib\site-packages'
# 用基础解释器的 pip 装进复制体的真实 site-packages：
# pywin32 等包依赖 .pth 文件，只有落在真正的 site-packages 下才会被 site.py 处理。
& $basePython -m pip install --disable-pip-version-check --no-warn-script-location --target $SitePkgs -r $Reqs
if ($LASTEXITCODE -ne 0) { Fail 'pip 安装后端依赖失败（检查网络或代理设置）' }

# pywin32 的 DLL 在部分 wheel 里需要显式补一份到包根，避免 win32crypt 导入失败
$pywin32System32 = Join-Path $SitePkgs 'pywin32_system32'
if (Test-Path -LiteralPath $pywin32System32) {
    Get-ChildItem -LiteralPath $pywin32System32 -Filter *.dll | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $SitePkgs -Force
    }
}

# ---------- 6. 验证依赖与后端可导入 ----------
Write-Step '验证依赖导入'
$verifyScript = @'
import importlib, sys
mods = ['uvicorn', 'fastapi', 'pydantic', 'requests', 'bs4', 'websockets', 'win11toast']
missing = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        missing.append('%s: %s' % (m, e))
if missing:
    print('MISSING: ' + '; '.join(missing))
    sys.exit(1)
print('all backend deps ok')
'@
$verifyFile = Join-Path $env:TEMP "gm_verify_deps_$(Get-Random).py"
Set-Content -LiteralPath $verifyFile -Value $verifyScript -Encoding UTF8
try {
    $verify = & $portable $verifyFile 2>&1
    $verifyCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $verifyFile -Force -ErrorAction SilentlyContinue
}
if ($verifyCode -ne 0) { Fail "依赖导入失败:`n$($verify -join "`n")" }
Write-Ok ($verify -join '')

# DPAPI 加密会话依赖 pywin32（缺失时后端会静默退化为 base64，不算致命）
$dpapi = & $portable -c "import win32crypt; print('win32crypt ok')" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'win32crypt 可用（会话 Cookie 走 DPAPI 加密）'
} else {
    Write-Warn2 "win32crypt 不可用，会话 Cookie 将退化为 base64 存储: $($dpapi -join '')"
}

# ---------- 7. 验证 backend 包可导入 ----------
Write-Step '验证 backend.api.app 可导入'
$probeData = Join-Path $env:TEMP "gm_runtime_probe_$(Get-Random)"
$env:GRADEMONITOR_DATA_DIR = $probeData
Push-Location $Root
try {
    $importTest = & $portable -c "import backend.api.app; print('backend import ok')" 2>&1
    $importCode = $LASTEXITCODE
} finally {
    Pop-Location
    Remove-Item -LiteralPath $probeData -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\GRADEMONITOR_DATA_DIR -ErrorAction SilentlyContinue
}
if ($importCode -ne 0) { Fail "backend 导入失败:`n$($importTest -join "`n")" }
Write-Ok ($importTest -join '')

# ---------- 8. 汇总 ----------
$size = (Get-ChildItem -LiteralPath $Tools -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Ok ("便携运行时就绪: {0} ({1:N1} MB)" -f $Tools, ($size / 1MB))
Write-Host '下一步: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1' -ForegroundColor Cyan
