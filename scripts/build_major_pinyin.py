"""生成前端专业名拼音表。

专业选择弹窗要按音序排列、按首字母分组，运行时不引入拼音库，因此把
培养方案里出现过的专业名一次性转成拼音，写成 Dart 常量表。

用法：
    PYTHONPATH=<pypinyin 所在目录> python3.11 scripts/build_major_pinyin.py
"""

from __future__ import annotations

import json
from pathlib import Path

from pypinyin import Style, lazy_pinyin

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "assets" / "curricula" / "curriculum_plan.json"
OUT = ROOT / "frontend" / "lib" / "views" / "progress" / "major_pinyin.dart"


def main() -> None:
    plan = json.loads(PLAN.read_text(encoding="utf-8"))
    names: set[str] = set()
    for year in plan.get("years", {}).values():
        # 每个年级是 {"majors": [...]}，不是裸列表。
        for major in year.get("majors", []):
            name = (major.get("name") or "").strip()
            if name:
                names.add(name)

    rows = []
    for name in sorted(names, key=lambda n: "".join(lazy_pinyin(n))):
        pinyin = "".join(lazy_pinyin(name, style=Style.NORMAL)).replace(" ", "")
        rows.append(f"  '{name}': '{pinyin}',")

    body = "\n".join(rows)
    OUT.write_text(
        "/// 培养方案专业名的拼音（离线生成，运行时不依赖拼音库）。\n"
        "///\n"
        "/// 生成脚本：scripts/build_major_pinyin.py；数据源：assets/curricula/curriculum_plan.json。\n"
        "/// 用途：专业选择弹窗按音序排列，并按首字母分组索引。\n"
        "library;\n"
        "\n"
        "const Map<String, String> kMajorPinyin = <String, String>{\n"
        f"{body}\n"
        "};\n"
        "\n"
        "String majorPinyin(String name) => kMajorPinyin[name] ?? name;\n"
        "\n"
        "/// 首字母分组键：取拼音第一个字母并大写，非 A–Z 统一归到 '#'。\n"
        "String majorInitial(String name) {\n"
        "  final pinyin = majorPinyin(name);\n"
        "  if (pinyin.isEmpty) return '#';\n"
        "  final first = pinyin.substring(0, 1).toUpperCase();\n"
        "  return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"{len(names)} 个专业名 -> {OUT}")


if __name__ == "__main__":
    main()
