import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_transcript_store.dart';

/// 目录后端:`<dir>/<base64url(circleId)>.jsonl`。
class DirectoryTranscriptBackend implements TranscriptBackend {
  DirectoryTranscriptBackend(this._dir);

  /// 目录来源(测试注入临时目录)。
  final Future<Directory> Function() _dir;

  Future<File> _file(String circleId) async {
    final d = await _dir();
    if (!await d.exists()) await d.create(recursive: true);
    return File('${d.path}${Platform.pathSeparator}'
        '${transcriptFileStem(circleId)}.jsonl');
  }

  @override
  Future<List<String>> readLines(String circleId) async {
    final f = await _file(circleId);
    if (!await f.exists()) return const [];
    return f.readAsLines();
  }

  @override
  Future<void> appendLines(String circleId, List<String> lines) async {
    final f = await _file(circleId);
    await f.writeAsString('${lines.join('\n')}\n',
        mode: FileMode.append, flush: true);
  }

  @override
  Future<void> delete(String circleId) async {
    final f = await _file(circleId);
    if (await f.exists()) await f.delete();
  }
}

TranscriptBackend createDefaultBackend() =>
    DirectoryTranscriptBackend(() async {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}lares_transcripts');
    });
