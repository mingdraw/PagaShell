import 'dart:convert';

const smallTextFileByteLimit = 2 * 1024 * 1024;

class SmallTextFile {
  const SmallTextFile(this.text, this.modified);

  final String text;
  final DateTime? modified;
}

/// Bounded UTF-8 access. Save must compare the original snapshot and reject
/// stale files before writing.
abstract interface class SmallTextFileAccess {
  Future<SmallTextFile> readSmallText(String path);
  Future<void> saveSmallText(String path, SmallTextFile original, String text);
}

class SmallTextFileException implements Exception {
  const SmallTextFileException(this.message);

  final String message;
}

void validateSmallText(String text) {
  if (utf8.encode(text).length > smallTextFileByteLimit) {
    throw const SmallTextFileException('文本文件不能超过 2 MiB');
  }
  if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(text)) {
    throw const SmallTextFileException('仅支持 UTF-8 文本文件');
  }
}
