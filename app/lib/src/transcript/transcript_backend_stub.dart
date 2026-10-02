import 'local_transcript_store.dart';

/// Web:只在内存里存(刷新即失)。
TranscriptBackend createDefaultBackend() => MemoryTranscriptBackend();
