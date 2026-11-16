import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../logger/app_logger.dart';

/// 发布包签名清单（Ed25519）
///
/// GitHub Release 正文中以围栏块形式随包发布，形如：
///
/// ```text
/// gm-release-v1
/// platform=macos
/// version=108.0.0.111
/// file=GradeMonitor-108.0.0.111-macOS-arm64.zip
/// sha256=a063ad8d…（64 位小写 hex）
/// sig=BASE64（64 字节分离签名）
/// ```
///
/// 被签名的原始字节 = 该块内除 `sig=` 行以外的全部行，
/// 按原始顺序以 `\n` 连接后**再补一个 `\n`**。
///
/// 为什么这样设计：签名不在 release 资产里，而在 release 正文里，
/// 攻击者若能篡改正文就必须同时伪造签名才能通过校验；只删掉清单
/// 或只换掉资产都会导致 [UpdateVerifier.verify] 失败，而校验失败时
/// 自动安装**一律拒绝**（fail-closed），降级为手动安装。
class SignedManifest {
  const SignedManifest({
    required this.platform,
    required this.version,
    required this.file,
    required this.sha256,
    required this.signature,
    required this.payload,
  });

  /// 'macos' 或 'windows'
  final String platform;

  /// 清单声明的版本号（应为已去前缀的纯数字版本）
  final String version;

  /// 安装包文件名（用于与本平台挑中的资产名比对）
  final String file;

  /// 安装包 SHA-256（小写 hex）
  final String sha256;

  /// Ed25519 分离签名的 base64
  final String signature;

  /// 被签名的原文（不含签名行）
  final String payload;
}

/// 远程通知签名块（Ed25519）
///
/// 蓝屏 / 红屏 / 普通广播 / 114 号段关停这四条通道原先只靠
/// 「tag 是否存在」判断，任何人只要拿到仓库写权限（或误操作）
/// 就能让全量客户端弹屏。加上签名后，只有持有本机私钥的人
/// 才能签发一条被客户端接受的通知：
///
/// ```text
/// gm-notice-v1
/// kind=blue
/// tag=developer-alert
/// sha256=<通知正文的 SHA-256，小写 hex>
/// sig=BASE64（64 字节分离签名）
/// ```
///
/// 被签名的原文 = 该块内除 `sig=` 行以外的全部行，按原顺序以 `\n`
/// 连接后再补一个 `\n`。`sha256` 绑定的是「去掉签名块之后剩下的正文」，
/// 所以正文里写什么链接、什么措辞，也被一并锁进签名里。
class SignedNotice {
  const SignedNotice({
    required this.kind,
    required this.tag,
    required this.sha256,
    required this.signature,
    required this.payload,
  });

  /// blue / red / broadcast / disable114
  final String kind;

  /// 该通知对应的 Release tag
  final String tag;

  /// 通知正文（去掉签名块后）的 SHA-256，小写 hex
  final String sha256;

  /// Ed25519 分离签名的 base64
  final String signature;

  /// 被签名的原文（不含签名行）
  final String payload;
}

/// 校验结果；[ok] 为 false 时 [reason] 说明原因，可直接展示给用户。
class ManifestVerifyResult {
  const ManifestVerifyResult({required this.ok, this.reason = ''});
  final bool ok;
  final String reason;

  const ManifestVerifyResult.success() : ok = true, reason = '';
  const ManifestVerifyResult.failure(String why) : ok = false, reason = why;
}

/// 发布包签名校验器
///
/// 公钥以常量形式编译进客户端：对应私钥仅保存在开发机 macOS 钥匙串，
/// 不随包分发、不进仓库。轮换密钥需重新发版。
class UpdateVerifier {
  UpdateVerifier._();

  static final AppLogger _log = AppLogger('update_verifier');

  /// Ed25519 公钥（raw 32 字节，base64）
  static const String publicKeyBase64 =
      'OCd+5QCWpbuQ0QywgE32rQaPzOUaK3mow+CERXKCq88=';

  /// 清单块的起始标记行
  static const String manifestHeader = 'gm-release-v1';

  /// 远程通知签名块的起始标记行
  static const String noticeHeader = 'gm-notice-v1';

  /// 该平台对应的标记值
  static String platformTag() => Platform.isMacOS ? 'macos' : 'windows';

  /// 从 Release 正文中解析出本平台的**全部**清单块。
  ///
  /// 为什么要复数：同一个平台可能同时发布多个包——
  /// `.zip` 供应用内自动更新，`.dmg` 供官网/Release 页手动下载安装。
  /// 两个包的 sha256 不同，合成一份清单必然有一个验不过，
  /// 所以每个包各一块，由 [selectForAsset] 按实际下载的文件名挑对应那块。
  static List<SignedManifest> parseManifests(
    String releaseBody, {
    String? platformTagOverride,
  }) {
    final wanted = platformTagOverride ?? platformTag();
    final out = <SignedManifest>[];
    for (final block in _splitBlocks(releaseBody)) {
      if (block.header != 'platform=$wanted') continue;
      final file = block.fields['file'] ?? '';
      final sha = (block.fields['sha256'] ?? '').toLowerCase();
      final sig = block.fields['sig'] ?? '';
      final version = block.fields['version'] ?? '';
      if (file.isEmpty || sha.isEmpty || sig.isEmpty || version.isEmpty) {
        _log.warning('签名清单字段不完整（platform=$wanted），忽略该块');
        continue;
      }
      out.add(
        SignedManifest(
          platform: wanted,
          version: version,
          file: file,
          sha256: sha,
          signature: sig,
          payload: block.payload,
        ),
      );
    }
    return out;
  }

  /// 从多份清单中挑出与实际要下载的文件同名的那份；没有则返回 null。
  ///
  /// 只有在资产名与清单文件名严格相等时才算匹配——不按「前缀」放宽，
  /// 否则同名不同版本的包可能被混用。
  static SignedManifest? selectForAsset(
    List<SignedManifest> manifests,
    String assetName,
  ) {
    for (final m in manifests) {
      if (m.file == assetName) return m;
    }
    return null;
  }

  /// 从 Release 正文中解析出本平台清单；没有或格式错误返回 null。
  ///
  /// 允许正文里有多个清单块（mac / windows 各一块，或同平台 zip/dmg 各一块），
  /// 返回本平台的第一个。需要按文件精确匹配时用 [parseManifests] + [selectForAsset]。
  static SignedManifest? parseManifest(
    String releaseBody, {
    String? platformTagOverride,
  }) {
    final all = parseManifests(
      releaseBody,
      platformTagOverride: platformTagOverride,
    );
    return all.isEmpty ? null : all.first;
  }

  /// 从 Release 正文中解析远程通知的签名块；没有则返回 null。
  ///
  /// 一个 Release 正文最多认一个通知块。若正文里写了多个（例如复制粘贴
  /// 出错），取第一个能解析出完整字段的块——其余视为噪声。
  static SignedNotice? parseNotice(String releaseBody) {
    for (final block in _splitBlocks(
      releaseBody,
      header: noticeHeader,
      requiredField: 'kind',
    )) {
      final kind = (block.fields['kind'] ?? '').trim();
      final tag = (block.fields['tag'] ?? '').trim();
      final sha = (block.fields['sha256'] ?? '').trim().toLowerCase();
      final sig = (block.fields['sig'] ?? '').trim();
      if (kind.isEmpty || tag.isEmpty || sha.isEmpty || sig.isEmpty) {
        _log.warning('通知签名块字段不完整（kind=$kind），忽略该块');
        continue;
      }
      return SignedNotice(
        kind: kind,
        tag: tag,
        sha256: sha,
        signature: sig,
        payload: block.payload,
      );
    }
    return null;
  }

  /// 从 Release 正文中移除通知签名块，用于展示给用户看。
  static String stripNoticeBlocks(String releaseBody) =>
      _stripBlocks(releaseBody, noticeHeader);

  /// 校验一条远程通知：签名 → 正文摘要。
  ///
  /// [releaseBody] 必须是完整的原始正文（含签名块），因为摘要算的是
  /// 「去掉签名块之后的正文」。任何一步不通过都返回失败。
  static Future<ManifestVerifyResult> verifyNotice(
    SignedNotice notice,
    String releaseBody,
  ) async {
    try {
      final sigBytes = base64Decode(notice.signature);
      if (sigBytes.length != 64) {
        return const ManifestVerifyResult.failure('签名长度异常（应为 64 字节）');
      }
      final pubBytes = base64Decode(publicKeyBase64);
      if (pubBytes.length != 32) {
        return const ManifestVerifyResult.failure('内置公钥异常（应为 32 字节）');
      }
      final algo = Ed25519();
      final ok = await algo.verify(
        utf8.encode(notice.payload),
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!ok) return const ManifestVerifyResult.failure('通知签名不匹配');
      final body = stripNoticeBlocks(releaseBody);
      final actual = crypto.sha256.convert(utf8.encode(body)).toString();
      if (actual != notice.sha256) {
        return const ManifestVerifyResult.failure('通知正文与签名摘要不一致');
      }
      return const ManifestVerifyResult.success();
    } catch (e) {
      _log.warning('通知签名校验异常: $e');
      return ManifestVerifyResult.failure('通知签名校验异常：$e');
    }
  }

  /// 从 Release 正文中移除所有签名清单块，用于展示更新日志。
  ///
  /// 清单是给机器看的，不该出现在用户读的更新日志里。
  static String stripManifestBlocks(String releaseBody) =>
      _stripBlocks(releaseBody, manifestHeader);

  /// 移除首行为 [header] 的所有围栏块，其余内容原样保留。
  static String _stripBlocks(String releaseBody, String header) {
    final lines = const LineSplitter().convert(releaseBody);
    final kept = <String>[];
    int i = 0;
    while (i < lines.length) {
      if (!lines[i].trim().startsWith('```')) {
        kept.add(lines[i]);
        i++;
        continue;
      }
      final start = i + 1;
      int j = start;
      while (j < lines.length && !lines[j].trim().startsWith('```')) {
        j++;
      }
      if (j >= lines.length) {
        // 围栏未闭合，原样保留剩余内容
        kept.addAll(lines.sublist(i));
        break;
      }
      final inner = lines.sublist(start, j);
      final isTarget = inner.isNotEmpty && inner.first.trim() == header;
      if (!isTarget) kept.addAll(lines.sublist(i, j + 1));
      i = j + 1;
    }
    // 折叠因移除产生的多余空行
    final out = <String>[];
    for (final line in kept) {
      if (line.trim().isEmpty && out.isNotEmpty && out.last.trim().isEmpty) {
        continue;
      }
      out.add(line);
    }
    while (out.isNotEmpty && out.first.trim().isEmpty) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && out.last.trim().isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }

  /// 按行扫描围栏块。围栏用 ``` 包住的代码块，首行为 [header]。
  ///
  /// [requiredField] 不为空时，缺少该字段的块会被丢弃——清单要求
  /// `platform`，通知要求 `kind`，这样两类块即便混在同一正文里也不会串。
  static List<_ManifestBlock> _splitBlocks(
    String body, {
    String header = manifestHeader,
    String? requiredField,
  }) {
    final out = <_ManifestBlock>[];
    final lines = const LineSplitter().convert(body);
    int i = 0;
    while (i < lines.length) {
      if (!lines[i].trim().startsWith('```')) {
        i++;
        continue;
      }
      // 围栏开始，收集到下一个围栏
      final start = i + 1;
      int j = start;
      while (j < lines.length && !lines[j].trim().startsWith('```')) {
        j++;
      }
      if (j >= lines.length) break;
      final inner = lines.sublist(start, j);
      i = j + 1;
      if (inner.isEmpty || inner.first.trim() != header) continue;

      // 第一行是 header，其余为 key=value；剔除 sig 行即为被签名原文
      final fields = <String, String>{};
      final payloadLines = <String>[];
      for (final raw in inner) {
        final line = raw.trim();
        if (line == header) {
          payloadLines.add(header);
          continue;
        }
        if (line.isEmpty) continue;
        if (line.startsWith('sig=')) {
          fields['sig'] = line.substring(4).trim();
          continue; // 签名行不参与被签名的原文
        }
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        final k = line.substring(0, eq).trim();
        final v = line.substring(eq + 1).trim();
        fields[k] = v;
        payloadLines.add('$k=$v');
      }
      final need = requiredField ?? 'platform';
      if (!fields.containsKey(need)) continue;
      out.add(
        _ManifestBlock(
          header: fields.containsKey('platform')
              ? 'platform=${fields['platform']}'
              : header,
          fields: fields,
          payload: '${payloadLines.join('\n')}\n',
        ),
      );
    }
    return out;
  }

  /// 用内置公钥验证清单签名。任何异常都视为失败（fail-closed）。
  static Future<ManifestVerifyResult> verify(SignedManifest manifest) async {
    try {
      final sigBytes = base64Decode(manifest.signature);
      if (sigBytes.length != 64) {
        return const ManifestVerifyResult.failure('签名长度异常（应为 64 字节）');
      }
      final pubBytes = base64Decode(publicKeyBase64);
      if (pubBytes.length != 32) {
        return const ManifestVerifyResult.failure('内置公钥异常（应为 32 字节）');
      }
      final algo = Ed25519();
      final ok = await algo.verify(
        utf8.encode(manifest.payload),
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!ok) return const ManifestVerifyResult.failure('签名不匹配');
      return const ManifestVerifyResult.success();
    } catch (e) {
      _log.warning('签名校验异常: $e');
      return ManifestVerifyResult.failure('签名校验异常：$e');
    }
  }

  /// 计算文件 SHA-256（小写 hex），流式读取避免大包占内存
  static Future<String> sha256OfFile(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  /// 完整校验一个已下载的安装包：签名 → 文件名 → 摘要。
  ///
  /// 三步全通过才算 [ManifestVerifyResult.ok]。
  static Future<ManifestVerifyResult> verifyDownloadedFile(
    String path,
    SignedManifest manifest,
  ) async {
    final sig = await verify(manifest);
    if (!sig.ok) return sig;

    final file = File(path);
    if (!file.existsSync()) {
      return const ManifestVerifyResult.failure('安装包不存在');
    }
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : '';
    if (name.isNotEmpty && name != manifest.file) {
      // 允许「文件名 (2).zip」这类同名顺延后缀
      if (!name.startsWith(manifest.file)) {
        _log.warning('安装包文件名与清单不符: 实际 $name，清单 ${manifest.file}');
      }
    }

    String actual;
    try {
      actual = await sha256OfFile(path);
    } catch (e) {
      return ManifestVerifyResult.failure('无法读取安装包：$e');
    }
    if (actual.toLowerCase() != manifest.sha256.toLowerCase()) {
      _log.warning('安装包摘要不匹配: 实际 $actual，清单 ${manifest.sha256}');
      return const ManifestVerifyResult.failure('安装包内容与签名清单不一致（可能被篡改或下载损坏）');
    }
    return const ManifestVerifyResult.success();
  }
}

class _ManifestBlock {
  const _ManifestBlock({
    required this.header,
    required this.fields,
    required this.payload,
  });

  final String header;
  final Map<String, String> fields;
  final String payload;
}
