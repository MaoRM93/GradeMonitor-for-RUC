"""把培养方案 PDF 抽取为结构化的修读要求清单（离线构建，不进运行时依赖）。

用法：
    PYTHONPATH=<pdfplumber 所在目录> python3 scripts/build_curriculum_plan.py

输出：assets/curricula/curriculum_plan.json
结构：{"years": {"2025": {"majors": [{"name", "total", "modules": [
          {"name", "credits", "items": [{"name", "credits", "note"}]}]}]}}}
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pdfplumber

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "curricula" / "curriculum_plan.json"
SOURCES = {
    "2024": Path("/Users/admin/Downloads/2024.pdf"),
    "2025": Path("/Users/admin/Downloads/2025.pdf"),
    "2026": Path("/Users/admin/Downloads/2026.pdf"),
}

GOAL = "（一）培养目标"
STOP_MARKS = ("（五）课程地图", "（五）培养路线图")
GENERIC_LABELS = {
    "必修模块",
    "选修模块",
    "必修",
    "选修",
    "限选",
    "任选",
    "课程模块",
    "模块",
    "部类核心课",
    "基础技能",
    "素质教育",
    "能力训练与拓展",
    "通识教育",
    "专业教育",
}
MODULE_NAMES = {
    "通识模块",
    "专业模块",
    "创新训练与科学研究",
    "素质拓展与发展指导",
    "立本模块",
    "卓越模块",
}
NUM_RE = re.compile(r"^\d+(?:\.\d+)?$")
FOOTNOTE_RE = re.compile(r"[〔（(]\s*\d+\s*[〕）)]")
TAIL_DIGIT_RE = re.compile(r"\d+$")
CREDIT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(?:个)?学分")
JUNK_MAJOR_RE = re.compile(r"^[一二三四五六七八九十]、|修读方案|修读指导计划|培养方案$")
# 课程表行一定以"学分 学期"结尾（如"经济法 2 2""社会科学研究方法 2 E"），
# 回溯专业名时不能把它们当成专业名——中法学院等版面把课程表压到"培养目标"上一行。
COURSE_ROW_RE = re.compile(r"\s\d+(?:\s+\S+)?$")
COURSE_MAP = "一、课程体系"
TABLE_HEADERS = ("课程名称 学分 开课学期", "课程模块 课程名称 学分 开课学期")
# 版心抬头、表头与学院名都不是专业名：中法学院等版面会把它们压在培养目标上方。
LAYOUT_NOISE = {
    "大类培养方案",
    "2024级本科生培养方案",
    "2025级本科生培养方案",
    "2026级本科生培养方案",
    "课程名称 学分 开课学期",
    "课程模块 课程名称 学分 开课学期",
}
# 修读要求正文被误当成子项名时的特征：这些字符只会出现在要求文本里。
BAD_NAME_RE = re.compile(r"[▲《》。；：，、]|完成|学分|所有课程|修读|共计|至少选修")
NAME_FIX = {
    "专业必修课": "专业必修",
    "毕业（设计）": "毕业论文（设计）",
    "政课": "思想政治理论课",
    "基础技能-公共外语": "公共外语课",
    "部类共同课部类基础课": "部类共同课/部类基础课",
    "公共外语2（非英语专业）": "公共外语课",
    "公共外语（非英语专业）": "公共外语课",
    "大学外语（英语专业）": "公共外语课",
    "公共外语2公共数学数据与信息技术平台课": "公共外语/公共数学/数据与信息技术平台课",
    "通识课新生研讨课6美育课程心理健康教育": "通识课/新生研讨课/美育课程/心理健康教育",
}
STATED_TOTAL_RE = re.compile(r"共\s*计?\s*(\d+(?:\.\d+)?)\s*学分")



def clean(cell: str | None) -> str:
    if not cell:
        return ""
    return re.sub(r"\s+", "", str(cell))


def item_name(cell: str) -> str:
    name = FOOTNOTE_RE.sub("", clean(cell))
    name = TAIL_DIGIT_RE.sub("", name)
    return NAME_FIX.get(name, name.strip())


def is_module_label(name: str) -> bool:
    if not name:
        return False
    if name in MODULE_NAMES:
        return True
    return name.endswith("模块") and "课" not in name


def credit_sum(text: str) -> float:
    return round(sum(float(v) for v in CREDIT_RE.findall(text)), 2)


def to_number(value: str) -> float | None:
    return float(value) if NUM_RE.match(value) else None


def layout(row: list[str | None]) -> tuple[int, int, int] | None:
    """从表头行解析 (修读要求起始列, 最低学分列, 模块总学分列)。"""
    values = [clean(c) for c in row]
    req = credit = -1
    for i, v in enumerate(values):
        if "修读要求" in v and req < 0:
            req = i
        if "最低学分" in v and credit < 0:
            credit = i
    if req < 0 or credit < 0:
        return None
    total = credit + 1 if credit + 1 < len(values) else credit
    return req, credit, total


def parse_row(
    row: list[str | None], cols: tuple[int, int, int]
) -> tuple[str, str, float | None, float | None, float | None, float | None]:
    """返回 (子项名, 修读要求, 子项学分, 模块总学分, 要求文本里写明的学分, 要求文本内学分和)。"""
    req_col, credit_col, total_col = cols
    values = [clean(c) for c in row]

    req_idx, req_text = -1, ""
    for i in range(req_col, min(max(credit_col, req_col), len(values))):
        if len(values[i]) > len(req_text):
            req_text, req_idx = values[i], i

    def num_at(index: int) -> float | None:
        return to_number(values[index]) if index < len(values) else None

    def usable(v: str) -> bool:
        if not v or NUM_RE.match(v) or v in GENERIC_LABELS or is_module_label(v):
            return False
        # 修读要求正文不能当子项名：它一定带句读或"学分"字样。
        return not BAD_NAME_RE.search(v)

    credit = num_at(credit_col)
    module_credit = num_at(total_col) if total_col != credit_col else None

    # 子项名是学分列左侧第一个"像名字"的格子。表格把名字写得比要求长时
    # （"国际性学习课程〔4〕" 对 "选修 2 学分课程"），从左往右扫才不会认错。
    name = ""
    for i in range(0, min(credit_col, len(values))):
        if usable(values[i]):
            name = item_name(values[i])
            break

    stated = STATED_TOTAL_RE.search(req_text)
    stated_value = float(stated.group(1)) if stated else None
    if credit is None:
        credit = stated_value if stated_value is not None else credit_sum(req_text)
    return name, req_text, credit, module_credit, stated_value, credit_sum(req_text)


def course_map_pages(pdf) -> list[tuple[int, str]]:
    """课程体系首页：专业名固定写在"一、课程体系"上一行，是最可靠的专业名来源。"""
    found: list[tuple[int, str]] = []
    for idx, page in enumerate(pdf.pages):
        text = page.extract_text() or ""
        if COURSE_MAP not in text:
            continue
        lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
        pos = next(i for i, ln in enumerate(lines) if COURSE_MAP in ln)
        for back in range(pos - 1, -1, -1):
            candidate = lines[back]
            if candidate in LAYOUT_NOISE:
                continue
            if candidate.endswith("学院") or len(candidate) > 24:
                continue
            found.append((idx, candidate))
            break
    return found


def major_pages(pdf) -> list[tuple[int, str]]:
    maps = course_map_pages(pdf)
    pages: list[tuple[int, str]] = []
    for idx, page in enumerate(pdf.pages):
        text = page.extract_text() or ""
        if GOAL not in text:
            continue
        lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
        pos = lines.index(GOAL)
        name = ""
        # 课程表压在本页上方时，回溯只会撞到课程名，直接用最近的课程体系页专业名。
        table_above = any(h in text for h in TABLE_HEADERS)
        for back in range(pos - 1, -1, -1) if not table_above else ():
            candidate = lines[back]
            if JUNK_MAJOR_RE.search(candidate) or len(candidate) > 24:
                continue
            if candidate in LAYOUT_NOISE or candidate.endswith("学院"):
                continue
            if len(candidate) < 2 or "：" in candidate or COURSE_ROW_RE.search(candidate):
                continue
            name = candidate
            break
        if not name:
            # 版面把课程表挤在培养目标上方时，退回到最近一个课程体系页的专业名。
            for map_idx, map_name in reversed(maps):
                if map_idx < idx:
                    name = map_name
                    break
        if not name:
            continue
        pages.append((idx, name))
    return pages


def split_combo(name: str) -> list[str]:
    """合并单元格会把多个子项名挤进一格（"部类共同课/部类基础课"）。"""
    parts = [p for p in re.split(r"[/、]", name) if p]
    return parts if len(parts) > 1 else []


def calibrate(module: dict) -> None:
    """让模块学分与子项明细对齐。

    模块学分来自"最低学分要求"列，是方案里写死的数；明细是重建出来的。
    两者严重不成比例（如 100 对 62）说明模块格读到了表头或相邻合并格里的
    串号值，此时以明细为准；否则差额记在最大的子项上（合并格里的分组小计
    常被读成子项，如会计学的"全英文课程 3"）。
    """
    if not module["items"]:
        return
    detail = round(sum(it["credits"] for it in module["items"]), 2)
    if detail > 0 and module["credits"] > 0 and max(detail, module["credits"]) > 1.5 * min(
        detail, module["credits"]
    ):
        module["credits"] = detail
    module["credits"] = round(module["credits"], 2)
    detail = round(sum(it["credits"] for it in module["items"]), 2)
    delta = round(module["credits"] - detail, 2)
    if abs(delta) > 0.01:
        target = max(module["items"], key=lambda x: x["credits"])
        target["credits"] = round(max(0.0, target["credits"] + delta), 2)


def collect_modules(pdf, start: int, end: int) -> list[dict]:
    modules: list[dict] = []
    current: dict | None = None
    pending: list[str] = []
    last_name = ""
    for idx in range(start, end):
        page = pdf.pages[idx]
        text = page.extract_text() or ""
        if "最低学分要求" not in text:
            continue
        if any(mark in text for mark in STOP_MARKS):
            continue
        for table in page.extract_tables():
            cols = None
            for row in table:
                joined = "".join(clean(c) for c in row)
                if "最低学分" in joined and "修读要求" in joined:
                    cols = layout(row)
                    continue
                if cols is None:
                    continue
                values = [clean(c) for c in row]
                head = values[0] if values else ""
                if is_module_label(head):
                    current = next((m for m in modules if m["name"] == head), None)
                    if current is None:
                        current = {"name": head, "credits": 0.0, "items": []}
                        modules.append(current)
                    pending = []
                if current is None:
                    continue
                name, req_text, credit, module_credit, stated, text_sum = parse_row(row, cols)
                # 模块总学分只认模块首行：跨页续页会把分组小计重复写进来（如 39 之后又出现 37）。
                if module_credit and (not current["items"] or not current["credits"]):
                    current["credits"] = max(current["credits"], module_credit)
                if not name and pending and credit:
                    name = pending.pop(0)
                elif not name and credit and last_name:
                    # 表格把同一子项的补充要求写成无名行（通识课程群里的新生研讨课、
                    # 心理健康教育），学分要累加回上一个子项，不能丢。
                    holder = next((it for it in current["items"] if it["name"] == last_name), None)
                    if holder is not None:
                        holder["credits"] = round(holder["credits"] + (stated or credit), 2)
                    continue
                if (
                    not name
                    or "学分" in name
                    or "课程模块" in name
                    or len(name) > 18
                    or BAD_NAME_RE.search(name)
                ):
                    continue
                combo = split_combo(name)
                if combo:
                    name, pending = combo[0], combo[1:]
                last_name = name
                existing = next((it for it in current["items"] if it["name"] == name), None)
                value = stated if stated is not None else (credit or 0.0)
                if existing is None:
                    current["items"].append(
                        {
                            "name": name,
                            "credits": round(value, 2),
                            "note": req_text[:200],
                            "stated": stated,
                            "text_sum": text_sum,
                        }
                    )
                else:
                    if credit or stated:
                        existing["credits"] = round(max(existing["credits"], value), 2)
                    existing["stated"] = stated
                    existing["text_sum"] = max(existing["text_sum"], text_sum)
    for module in modules:
        if not module["credits"]:
            module["credits"] = round(sum(it["credits"] for it in module["items"]), 2)
        # 分组行（"部类核心课"下的部类共同课）在学分列写的是整组小计，
        # 有时还会串成"110"这种拼接值。要求文本里写明了更小学分时以文本为准。
        if sum(it["credits"] for it in module["items"]) > module["credits"] + 0.01:
            for it in module["items"]:
                candidates = [v for v in (it.get("stated"), it.get("text_sum")) if v]
                if candidates and min(candidates) < it["credits"]:
                    it["credits"] = round(min(candidates), 2)
        module["credits"] = round(module["credits"], 2)
        # 反向缺口：表格把"必选 20 + 限选 26"写成一行、学分列只留 20，
        # 少掉的学分藏在要求文本里，按差额补回最接近的子项。
        # 必须在 pop 之前做，否则 text_sum 已经没了，永远补不进去。
        deficit = round(module["credits"] - sum(it["credits"] for it in module["items"]), 2)
        if deficit > 0:
            for it in sorted(module["items"], key=lambda x: x.get("text_sum", 0) - x["credits"]):
                delta = round(it.get("text_sum", 0) - it["credits"], 2)
                if delta <= 0:
                    continue
                take = min(delta, deficit)
                it["credits"] = round(it["credits"] + take, 2)
                deficit = round(deficit - take, 2)
                if deficit <= 0:
                    break
        gaps = [it for it in module["items"] if not it["credits"]]
        if len(gaps) == 1:
            known = sum(it["credits"] for it in module["items"] if it["credits"])
            rest = round(module["credits"] - known, 2)
            if rest > 0:
                gaps[0]["credits"] = rest
        for it in module["items"]:
            it.pop("stated", None)
            it.pop("text_sum", None)
        calibrate(module)
    return [m for m in modules if m["items"]]


def build() -> dict:
    years: dict[str, dict] = {}
    for year, path in SOURCES.items():
        if not path.exists():
            print(f"跳过 {year}：{path} 不存在", file=sys.stderr)
            continue
        pdf = pdfplumber.open(path)
        starts = major_pages(pdf)
        majors: dict[str, dict] = {}
        for order, (page_idx, name) in enumerate(starts):
            next_idx = starts[order + 1][0] if order + 1 < len(starts) else len(pdf.pages)
            end = next_idx
            for probe in range(page_idx, next_idx):
                if any(mark in (pdf.pages[probe].extract_text() or "") for mark in STOP_MARKS):
                    end = probe + 1
                    break
            modules = collect_modules(pdf, page_idx, end)
            if not modules:
                continue
            key = name[:-2] if name.endswith("专业") else name
            total = round(sum(m["credits"] for m in modules), 2)
            entry = majors.get(key)
            if entry is None:
                majors[key] = {"name": key, "total": total, "modules": modules}
            else:
                for module in modules:
                    same = next((m for m in entry["modules"] if m["name"] == module["name"]), None)
                    if same is None:
                        entry["modules"].append(module)
                    else:
                        same["credits"] = max(same["credits"], module["credits"])
                        for it in module["items"]:
                            if not any(x["name"] == it["name"] for x in same["items"]):
                                same["items"].append(it)
                        calibrate(same)
                entry["total"] = round(sum(m["credits"] for m in entry["modules"]), 2)
        years[year] = {"majors": list(majors.values())}
        print(f"{year}: {len(majors)} 个专业", file=sys.stderr)
        pdf.close()
    return {"years": years}


def main() -> None:
    plan = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(plan, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"写入 {OUT}（{OUT.stat().st_size} 字节）", file=sys.stderr)


if __name__ == "__main__":
    main()
