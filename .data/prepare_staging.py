# 准备 Inno Setup 打包所需的 staging 目录
# 内容：前端 Release + Python 便携版 + backend + 完整 VC++ 运行库
import os
import shutil
import sys

ROOT = r"D:\Projects\GradeDetector_Windows_4"
RELEASE = os.path.join(ROOT, "frontend", "build", "windows", "x64", "runner", "Release")
BACKEND = os.path.join(ROOT, "backend")
RUNTIME_TOOLS = os.path.join(ROOT, "runtime", "tools")
DATA_DIR = os.path.join(ROOT, ".data")
STAGING = os.path.join(DATA_DIR, "staging")

# VC++ 运行库（应用本地部署，确保"不缺运行库"）
VC_REDIST = os.path.join(
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools",
    "VC", "Redist", "MSVC", "14.51.36231", "x64", "Microsoft.VC145.CRT",
)


def main():
    for p in (RELEASE, BACKEND, RUNTIME_TOOLS, VC_REDIST):
        if not os.path.exists(p):
            print(f"[FAIL] 缺少: {p}")
            sys.exit(1)

    os.makedirs(DATA_DIR, exist_ok=True)

    # 1. 重建 staging
    if os.path.exists(STAGING):
        shutil.rmtree(STAGING, ignore_errors=True)
    os.makedirs(STAGING)

    # 2. 复制前端 Release（exe + dll + data/）
    print("[1/4] 复制前端 Release ...")
    for item in os.listdir(RELEASE):
        s = os.path.join(RELEASE, item)
        d = os.path.join(STAGING, item)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)

    # 3. 复制 backend（排除 __pycache__）
    print("[2/4] 复制 backend ...")
    shutil.copytree(
        BACKEND,
        os.path.join(STAGING, "backend"),
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )

    # 4. 复制 Python runtime（排除开发用目录 include/libs 及缓存）
    print("[3/4] 复制 Python runtime ...")
    shutil.copytree(
        RUNTIME_TOOLS,
        os.path.join(STAGING, "runtime", "tools"),
        ignore=shutil.ignore_patterns("include", "libs", "__pycache__", "*.pyc"),
    )

    # 5. 复制完整 VC++ 运行库到 exe 同级（确保不缺运行库）
    print("[4/4] 复制 VC++ 运行库 ...")
    copied = 0
    for f in os.listdir(VC_REDIST):
        if f.lower().endswith(".dll"):
            shutil.copy2(os.path.join(VC_REDIST, f), os.path.join(STAGING, f))
            copied += 1
    print(f"  已复制 {copied} 个运行库 DLL")

    total = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fs in os.walk(STAGING) for f in fs
    )
    print(f"\nstaging 完成: {STAGING}")
    print(f"总大小: {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
