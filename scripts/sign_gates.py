#!/usr/bin/env python3
"""离线签发一条远程功能开关指令（不启动 App、不联网）。

产出的是可直接贴进 GitHub Release 正文的签名围栏块。客户端每小时拉一次
`control-v*` 频道的 Release，验签通过且 rev 更大才应用。

用法：
  ./scripts/sign_gates.py --rev 1 --off Flag-1010
  ./scripts/sign_gates.py --rev 2 --off Flag-1010,Flag-1020
  ./scripts/sign_gates.py --rev 3 --on  Flag-1010,Flag-1020
  ./scripts/sign_gates.py --rev 4                       # 空表 = 撤销全部远程覆盖

注意：控制密钥仅保存在开发机钥匙串。UI 发布会自动合并历史远程状态；本脚本
签发的是完整快照，使用时应自行提供想保留的全部状态。
"""
import argparse
import datetime
import os
import sys

# 支持从任意工作目录运行，签名私钥始终只从开发机钥匙串读取。
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main() -> int:
    ap = argparse.ArgumentParser(description="签发远程功能开关指令块")
    ap.add_argument("--rev", type=int, required=True,
                    help="指令序号，必须严格大于客户端已生效的那个")
    ap.add_argument("--off", default="", help="要禁用的 Flag 编号，逗号分隔")
    ap.add_argument("--on", default="", help="要恢复的 Flag 编号，逗号分隔")
    ap.add_argument("--issued-at", default="",
                    help="签发时间（默认当前本地时间，带时区）")
    a = ap.parse_args()

    if a.rev <= 0:
        print("rev 必须大于 0", file=sys.stderr)
        return 1

    gates: dict[str, bool] = {}
    for gid in [x.strip() for x in a.off.split(",") if x.strip()]:
        gates[gid] = False
    for gid in [x.strip() for x in a.on.split(",") if x.strip()]:
        gates[gid] = True

    stamp = a.issued_at.strip() or datetime.datetime.now().astimezone().isoformat(
        timespec="seconds"
    )
    from backend.storage.remote_gates import build_block
    print(build_block(a.rev, gates, stamp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
