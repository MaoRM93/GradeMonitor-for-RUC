import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'major_pinyin.dart';

/// 专业选择弹窗：按音序分组，右侧 A-Z 索引直达。
///
/// 专业最多近百个，下拉选单翻起来很累；这里做成通讯录式：
/// 左边按拼音首字母分组列全部专业，右边竖排字母点一下就跳过去。
Future<String?> showMajorPicker(
  BuildContext context, {
  required List<String> majors,
  String? current,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .35),
    builder: (ctx) => _MajorPicker(majors: majors, current: current),
  );
}

class _MajorPicker extends StatefulWidget {
  const _MajorPicker({required this.majors, this.current});

  final List<String> majors;
  final String? current;

  @override
  State<_MajorPicker> createState() => _MajorPickerState();
}

class _MajorPickerState extends State<_MajorPicker> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  late final List<String> _letters;
  late final Map<String, List<String>> _groups;

  @override
  void initState() {
    super.initState();
    final groups = <String, List<String>>{};
    for (final name in widget.majors) {
      groups.putIfAbsent(majorInitial(name), () => <String>[]).add(name);
    }
    for (final list in groups.values) {
      list.sort((a, b) => majorPinyin(a).compareTo(majorPinyin(b)));
    }
    _groups = Map<String, List<String>>.fromEntries(
      groups.entries.toList()..sort((a, b) {
        // `#` 永远排在最后：那是没有拼音的兜底分组。
        if (a.key == '#') return 1;
        if (b.key == '#') return -1;
        return a.key.compareTo(b.key);
      }),
    );
    _letters = _groups.keys.toList();
    for (final letter in _letters) {
      _headerKeys[letter] = GlobalKey();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpTo(String letter) {
    final ctx = _headerKeys[letter]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(48),
      child: Container(
        width: 560,
        height: 620,
        decoration: BoxDecoration(
          color: AppShape.groupFill(cs),
          borderRadius: AppShape.outer,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
              child: Row(
                children: [
                  Text(
                    '选择专业',
                    style: TextStyle(
                      fontFamily: AppTheme.serifFontFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _list(cs)),
                  _indexRail(cs),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(ColorScheme cs) {
    final rows = <Widget>[];
    for (final letter in _letters) {
      rows.add(
        Padding(
          key: _headerKeys[letter],
          padding: const EdgeInsets.fromLTRB(24, 12, 16, 6),
          child: Text(
            letter,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.primary,
              letterSpacing: 1,
            ),
          ),
        ),
      );
      for (final name in _groups[letter]!) {
        final selected = name == widget.current;
        rows.add(
          InkWell(
            onTap: () => Navigator.of(context).pop(name),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: selected ? AppShape.overlayFill(cs) : null,
                borderRadius: AppShape.inner,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: cs.onSurface.withValues(alpha: .9),
                      ),
                    ),
                  ),
                  if (selected) Icon(Icons.check, size: 16, color: cs.primary),
                ],
              ),
            ),
          ),
        );
      }
    }
    // 不用 ListView：右侧字母索引要跳到一个还没渲染的分组，而懒加载的
    // ListView 里未构建的行拿不到 GlobalKey 的 context，跳转会静默失败。
    // 百来个专业全部构建的代价可以忽略，换来索引一定生效。
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  Widget _indexRail(ColorScheme cs) {
    return Container(
      width: 34,
      margin: const EdgeInsets.fromLTRB(0, 8, 10, 16),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppShape.insetFill(cs),
        borderRadius: AppShape.inner,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final letter in _letters)
            InkWell(
              onTap: () => _jumpTo(letter),
              borderRadius: AppShape.inner,
              child: SizedBox(
                width: 22,
                child: Text(
                  letter,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: .62),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
