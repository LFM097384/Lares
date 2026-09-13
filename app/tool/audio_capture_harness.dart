// THROWAWAY VERIFICATION SPIKE HARNESS.
//
// Goal: prove whether livekit_client 2.12.0 delivers raw per-participant PCM
// audio frames on Flutter Windows via AudioTrack.addAudioRenderer.
//
// Run with:  flutter run -d windows -t lib/spike_main.dart
//
// Results are written (synchronously, flushed) to:
//   D:\Projects\Lares\app\spike_out\spike_log.txt
// WAV dumps go to:
//   D:\Projects\Lares\app\spike_out\<identity>.wav
// On-demand dump trigger (create this file from outside):
//   D:\Projects\Lares\app\spike_out\CMD_DUMP

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const String kOutDir = r'D:\Projects\Lares\app\spike_out';
const String kLogPath = r'D:\Projects\Lares\app\spike_out\spike_log.txt';
const String kCmdDumpPath = r'D:\Projects\Lares\app\spike_out\CMD_DUMP';

const String kSignalUrl = 'ws://127.0.0.1:8787';
const String kCircleId = 'spike';
const String kUserId = 'u_spike';
const String kDeviceId = 'd_spike';

const int kReqSampleRate = 16000;
const int kReqChannels = 1;

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

final List<String> logLines = <String>[];
final ValueNotifier<int> logRevision = ValueNotifier<int>(0);

String _ts() {
  final DateTime n = DateTime.now();
  String p(int v, int w) => v.toString().padLeft(w, '0');
  return '${p(n.hour, 2)}:${p(n.minute, 2)}:${p(n.second, 2)}.${p(n.millisecond, 3)}';
}

void log(String msg) {
  final String line = '[${_ts()}] $msg';
  // 1) stdout
  // ignore: avoid_print
  print(line);
  // 2) file, synchronous + flushed (external readers depend on this)
  try {
    File(kLogPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // never let logging kill the harness
  }
  // 3) in-memory for UI
  try {
    logLines.add(line);
    if (logLines.length > 2000) {
      logLines.removeRange(0, logLines.length - 2000);
    }
    logRevision.value = logRevision.value + 1;
  } catch (_) {}
}

void logBanner(String msg) {
  log('==========================================================');
  log(msg);
  log('==========================================================');
}

void _prepareOutDir() {
  try {
    Directory(kOutDir).createSync(recursive: true);
  } catch (_) {}
  try {
    final File f = File(kLogPath);
    if (f.existsSync()) {
      f.deleteSync();
    }
  } catch (_) {}
  try {
    final File c = File(kCmdDumpPath);
    if (c.existsSync()) {
      c.deleteSync();
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Per-identity capture state
// ---------------------------------------------------------------------------

class CaptureState {
  final String identity;
  BytesBuilder bytes = BytesBuilder(copy: true);

  int totalFrames = 0;
  int totalBytes = 0;

  int framesThisSec = 0;
  int bytesThisSec = 0;

  bool sawFirstFrame = false;
  int reportedSampleRate = 0;
  int reportedChannels = 0;
  String reportedFormat = '<none>';

  int registrationCount = 0;

  /// Byte offsets (into [bytes]) at which each 1-second wall-clock tick fell.
  final List<int> secondBoundaryOffsets = <int>[];

  /// Byte count already consumed by a previous auto-dump, used so the 10s
  /// auto-trigger can fire again after a reset.
  int autoDumpedAtBytes = 0;

  CaptureState(this.identity);

  void reset() {
    bytes = BytesBuilder(copy: true);
    totalBytes = 0;
    totalFrames = 0;
    secondBoundaryOffsets.clear();
    autoDumpedAtBytes = 0;
  }
}

final Map<String, CaptureState> captures = <String, CaptureState>{};
final Map<String, Future<void> Function()> rendererCancels = <String, Future<void> Function()>{};

CaptureState _cap(String identity) =>
    captures.putIfAbsent(identity, () => CaptureState(identity));

// ---------------------------------------------------------------------------
// Signaling
// ---------------------------------------------------------------------------

WebSocket? signalSocket;
bool signalWantsOpen = true;
Completer<Map<String, dynamic>>? tokenCompleter;
int signalAttempt = 0;

Future<void> connectSignaling() async {
  signalAttempt++;
  final int attempt = signalAttempt;
  log('[signal] connect attempt #$attempt -> $kSignalUrl');
  try {
    final WebSocket ws = await WebSocket.connect(kSignalUrl);
    signalSocket = ws;
    log('[signal] connect attempt #$attempt SUCCESS (readyState=${ws.readyState})');

    ws.listen(
      (dynamic raw) {
        try {
          final String s = raw is String ? raw : utf8.decode(raw as List<int>);
          final dynamic decoded = jsonDecode(s);
          if (decoded is! Map) {
            log('[signal] recv non-object message: $s');
            return;
          }
          final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);
          final String t = '${m['t']}';
          log('[signal] recv t=$t');
          if (t == 'token') {
            final String url = '${m['url']}';
            final String token = '${m['token']}';
            log('[signal] token received url=$url tokenLen=${token.length}');
            final Completer<Map<String, dynamic>>? c = tokenCompleter;
            if (c != null && !c.isCompleted) {
              c.complete(<String, dynamic>{'url': url, 'token': token});
            }
          }
        } catch (e, st) {
          log('[signal] ERROR parsing message: $e');
          log('[signal] $st');
        }
      },
      onError: (Object e, StackTrace st) {
        log('[signal] !!!! SOCKET ERROR: $e');
        log('[signal] $st');
      },
      onDone: () {
        log('[signal] !!!! SOCKET CLOSED code=${signalSocket?.closeCode} reason=${signalSocket?.closeReason}');
        signalSocket = null;
        if (signalWantsOpen) {
          log('[signal] scheduling reconnect in 3s');
          Timer(const Duration(seconds: 3), () {
            connectSignaling().catchError((Object e) {
              log('[signal] reconnect failed: $e');
            });
          });
        }
      },
      cancelOnError: false,
    );

    final String hello = jsonEncode(<String, dynamic>{
      't': 'hello',
      'userId': kUserId,
      'deviceId': kDeviceId,
      'name': 'Spike',
      'platform': 'windows',
    });
    ws.add(hello);
    log('[signal] sent hello');

    await Future<void>.delayed(const Duration(milliseconds: 300));

    final String join = jsonEncode(<String, dynamic>{'t': 'join', 'circleId': kCircleId});
    ws.add(join);
    log('[signal] sent join circleId=$kCircleId');
  } catch (e, st) {
    log('[signal] connect attempt #$attempt FAILED: $e');
    log('[signal] $st');
    signalSocket = null;
    if (signalWantsOpen) {
      log('[signal] scheduling reconnect in 3s');
      Timer(const Duration(seconds: 3), () {
        connectSignaling().catchError((Object e2) {
          log('[signal] reconnect failed: $e2');
        });
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

String sanitizeIdentity(String identity) {
  final StringBuffer sb = StringBuffer();
  for (final int c in identity.codeUnits) {
    final String ch = String.fromCharCode(c);
    if (RegExp(r'[A-Za-z0-9._\-]').hasMatch(ch)) {
      sb.write(ch);
    } else {
      sb.write('_');
    }
  }
  final String out = sb.toString();
  return out.isEmpty ? 'unknown' : out;
}

/// Goertzel magnitude of [x] at [freq] Hz given sample rate [fs].
double goertzelMag(Float64List x, double freq, double fs) {
  final int n = x.length;
  if (n == 0) return 0.0;
  final double w = 2 * pi * freq / fs;
  final double cosW = cos(w);
  final double sinW = sin(w);
  final double coeff = 2 * cosW;
  double s1 = 0.0;
  double s2 = 0.0;
  for (int i = 0; i < n; i++) {
    final double s0 = x[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  final double real = s1 - s2 * cosW;
  final double imag = s2 * sinW;
  return sqrt(real * real + imag * imag);
}

Uint8List buildWavHeader({
  required int sampleRate,
  required int channels,
  required int dataBytes,
}) {
  const int bitsPerSample = 16;
  final int byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final int blockAlign = channels * bitsPerSample ~/ 8;
  final Uint8List header = Uint8List(44);
  final ByteData bd = ByteData.view(header.buffer, header.offsetInBytes, 44);

  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      header[offset + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + dataBytes, Endian.little); // ChunkSize
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little); // Subchunk1Size (PCM)
  bd.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little); // Subchunk2Size
  return header;
}

void analyzeAndDump(String identity) {
  final CaptureState? st = captures[identity];
  if (st == null) {
    log('[analyze] identity=$identity NO STATE — nothing to analyze');
    return;
  }

  final Uint8List bytes = st.bytes.toBytes();
  logBanner('[analyze] BEGIN identity=$identity');
  log('[analyze] identity=$identity totalFrames=${st.totalFrames} totalBytes=${bytes.length}');

  if (bytes.length < 4) {
    log('[analyze] identity=$identity NOT ENOUGH DATA (${bytes.length} bytes) — aborting analysis');
    logBanner('[analyze] END identity=$identity');
    return;
  }

  final int sampleRate = st.reportedSampleRate > 0 ? st.reportedSampleRate : kReqSampleRate;
  final int channels = st.reportedChannels > 0 ? st.reportedChannels : kReqChannels;

  final int totalSamples = bytes.length ~/ 2;
  final ByteData bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
  final Int16List samples = Int16List(totalSamples);
  for (int i = 0; i < totalSamples; i++) {
    samples[i] = bd.getInt16(i * 2, Endian.little);
  }

  double sumSq = 0.0;
  double sum = 0.0;
  int peakAbs = 0;
  int minV = 32767;
  int maxV = -32768;
  int nonZero = 0;
  for (int i = 0; i < totalSamples; i++) {
    final int v = samples[i];
    sumSq += v.toDouble() * v.toDouble();
    sum += v.toDouble();
    final int a = v.abs();
    if (a > peakAbs) peakAbs = a;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
    if (v != 0) nonZero++;
  }
  final double rms = totalSamples == 0 ? 0.0 : sqrt(sumSq / totalSamples);
  final double mean = totalSamples == 0 ? 0.0 : sum / totalSamples;
  final double durationSec = totalSamples / (sampleRate * channels);
  final double pctNonZero = totalSamples == 0 ? 0.0 : (nonZero * 100.0 / totalSamples);

  log('[analyze] identity=$identity reportedSampleRate=$sampleRate reportedChannels=$channels reportedFormat=${st.reportedFormat}');
  log('[analyze] identity=$identity totalBytes=${bytes.length} totalSamples=$totalSamples impliedDurationSec=${durationSec.toStringAsFixed(3)}');
  log('[analyze] identity=$identity rms=${rms.toStringAsFixed(3)} peakAbs=$peakAbs min=$minV max=$maxV mean=${mean.toStringAsFixed(3)}');
  log('[analyze] identity=$identity nonZeroSamples=$nonZero (${pctNonZero.toStringAsFixed(2)}%)');

  // ---- per-1-second-window RMS ----
  final int winSamples = sampleRate * channels;
  if (winSamples > 0) {
    final int wholeWindows = totalSamples ~/ winSamples;
    for (int w = 0; w < wholeWindows; w++) {
      double ss = 0.0;
      int pk = 0;
      final int base = w * winSamples;
      for (int i = 0; i < winSamples; i++) {
        final int v = samples[base + i];
        ss += v.toDouble() * v.toDouble();
        final int a = v.abs();
        if (a > pk) pk = a;
      }
      final double wr = sqrt(ss / winSamples);
      log('[rms] identity=$identity sec=$w rms=${wr.toStringAsFixed(3)} peak=$pk');
    }
    if (wholeWindows == 0) {
      log('[rms] identity=$identity (no whole 1-second window yet: $totalSamples samples < $winSamples)');
    }
  }

  // ---- (a) Schmitt-trigger zero-crossing frequency estimate ----
  double zeroCrossHz = 0.0;
  int crossings = 0;
  {
    // DC removal over the whole capture
    final double dc = mean;
    final double threshold = 0.15 * peakAbs;
    int state = 0; // 0 unknown, 1 positive, -1 negative
    for (int i = 0; i < totalSamples; i++) {
      final double v = samples[i] - dc;
      if (v > threshold) {
        if (state != 1) {
          if (state != 0) crossings++;
          state = 1;
        }
      } else if (v < -threshold) {
        if (state != -1) {
          if (state != 0) crossings++;
          state = -1;
        }
      }
    }
    zeroCrossHz = durationSec > 0 ? (crossings / 2.0) / durationSec : 0.0;
    log('[freq] identity=$identity method=zerocross crossings=$crossings durationSec=${durationSec.toStringAsFixed(3)} '
        'threshold=${threshold.toStringAsFixed(2)} estHz=${zeroCrossHz.toStringAsFixed(3)}');
  }

  // ---- (b) Goertzel DFT magnitude scan, 50..2000 Hz, over 1s mid window ----
  double goertzelPeakHz = 0.0;
  {
    final int wlen = min(sampleRate, totalSamples);
    if (wlen < 64) {
      log('[freq] identity=$identity method=goertzel SKIPPED (window too small: $wlen samples)');
    } else {
      int start = (totalSamples - wlen) ~/ 2;
      if (start < 0) start = 0;
      final Float64List x = Float64List(wlen);
      double wsum = 0.0;
      for (int i = 0; i < wlen; i++) {
        wsum += samples[start + i].toDouble();
      }
      final double wmean = wsum / wlen;
      for (int i = 0; i < wlen; i++) {
        x[i] = samples[start + i].toDouble() - wmean;
      }

      final double fs = sampleRate.toDouble();
      final int lo = 50;
      final int hi = min(2000, (fs / 2).floor() - 1);
      final List<double> mags = <double>[];
      final List<int> freqs = <int>[];
      for (int f = lo; f <= hi; f++) {
        freqs.add(f);
        mags.add(goertzelMag(x, f.toDouble(), fs));
      }

      // pick top-3 peaks with >=15 Hz separation
      final List<int> order = List<int>.generate(mags.length, (int i) => i);
      order.sort((int a, int b) => mags[b].compareTo(mags[a]));
      final List<int> chosen = <int>[];
      for (final int idx in order) {
        bool tooClose = false;
        for (final int c in chosen) {
          if ((freqs[idx] - freqs[c]).abs() < 15) {
            tooClose = true;
            break;
          }
        }
        if (!tooClose) chosen.add(idx);
        if (chosen.length >= 3) break;
      }

      final StringBuffer sb = StringBuffer('[freq] identity=$identity method=goertzel');
      for (int i = 0; i < chosen.length; i++) {
        sb.write(' peak${i + 1}=${freqs[chosen[i]]}Hz(${mags[chosen[i]].toStringAsExponential(4)})');
      }
      sb.write(' windowSamples=$wlen windowStart=$start scanRange=${lo}-${hi}Hz');
      log(sb.toString());

      if (chosen.isNotEmpty) {
        goertzelPeakHz = freqs[chosen[0]].toDouble();
      }
    }
  }

  // ---- INTERPRETATION ----
  final double measured = goertzelPeakHz > 0 ? goertzelPeakHz : zeroCrossHz;
  final String src = goertzelPeakHz > 0 ? 'goertzel' : 'zerocross';
  bool near(double target) => target > 0 && (measured - target).abs() / target <= 0.05;

  const double f440 = 440.0;
  const double f440At48k = 440.0 * 16000.0 / 48000.0; // 146.666..
  const double f880 = 880.0;
  const double f880At48k = 880.0 * 16000.0 / 48000.0; // 293.333..

  log('==========================================================');
  log('[VERDICT] identity=$identity measuredHz=${measured.toStringAsFixed(3)} (source=$src) '
      'reportedSampleRate=$sampleRate requestedSampleRate=$kReqSampleRate');
  if (near(f440)) {
    log('[VERDICT] identity=$identity SAMPLE RATE GENUINELY HONORED: measured ~440Hz at reported 16000Hz.');
  } else if (near(f440At48k)) {
    log('[VERDICT] identity=$identity !!!! SAMPLE RATE IS A LIE !!!! measured ~147Hz => data is really 48000Hz mislabeled as 16000Hz.');
  } else if (near(f880)) {
    log('[VERDICT] identity=$identity 880Hz BOT (second bot) — SAMPLE RATE HONORED: measured ~880Hz at reported 16000Hz.');
  } else if (near(f880At48k)) {
    log('[VERDICT] identity=$identity !!!! SAMPLE RATE IS A LIE !!!! measured ~293Hz => 880Hz bot data is really 48000Hz mislabeled as 16000Hz.');
  } else {
    log('[VERDICT] identity=$identity INCONCLUSIVE measured=${measured.toStringAsFixed(3)}Hz — '
        'expected 440 (honored) or 146.7 (48k mislabeled).');
  }
  log('==========================================================');

  // ---- WAV dump ----
  try {
    final String safe = sanitizeIdentity(identity);
    final String wavPath = '$kOutDir\\$safe.wav';
    final Uint8List header = buildWavHeader(
      sampleRate: sampleRate,
      channels: channels,
      dataBytes: bytes.length,
    );
    final File wf = File(wavPath);
    final RandomAccessFile raf = wf.openSync(mode: FileMode.write);
    raf.writeFromSync(header);
    raf.writeFromSync(bytes);
    raf.flushSync();
    raf.closeSync();
    final int size = wf.lengthSync();
    log('[wav] identity=$identity wrote ${wf.absolute.path} sizeBytes=$size '
        '(header=44 data=${bytes.length} sampleRate=$sampleRate channels=$channels '
        'byteRate=${sampleRate * channels * 2} blockAlign=${channels * 2} bitsPerSample=16)');
  } catch (e, stk) {
    log('[wav] identity=$identity WRITE FAILED: $e');
    log('[wav] $stk');
  }

  logBanner('[analyze] END identity=$identity');
}

// ---------------------------------------------------------------------------
// LiveKit
// ---------------------------------------------------------------------------

Room? gRoom;
EventsListener<RoomEvent>? gListener;

void attachRenderer(String identity, AudioTrack track) {
  final CaptureState st = _cap(identity);
  st.registrationCount++;
  log('[renderer] registration #${st.registrationCount} for $identity');
  try {
    final Future<void> Function() cancel = track.addAudioRenderer(
      onFrame: (AudioFrame frame) {
        final CaptureState s = _cap(identity);
        if (!s.sawFirstFrame) {
          s.sawFirstFrame = true;
          s.reportedSampleRate = frame.sampleRate;
          s.reportedChannels = frame.channels;
          s.reportedFormat = frame.format.toString();
          final int impliedSamples = frame.data.length ~/ 2;
          final double impliedFrameMs = frame.sampleRate > 0
              ? impliedSamples / frame.sampleRate * 1000.0
              : 0.0;
          log('==========================================================');
          log('[FIRSTFRAME] identity=$identity requested(sampleRate=$kReqSampleRate channels=$kReqChannels format=Int16) '
              'ACTUAL(sampleRate=${frame.sampleRate} channels=${frame.channels} format=${frame.format} '
              'dataLen=${frame.data.length}) impliedSamples=$impliedSamples '
              'impliedFrameMs=${impliedFrameMs.toStringAsFixed(3)}');
          log('==========================================================');
        }
        s.totalFrames++;
        s.framesThisSec++;
        s.totalBytes += frame.data.length;
        s.bytesThisSec += frame.data.length;
        s.bytes.add(frame.data);
      },
      options: const AudioRendererOptions(
        sampleRate: kReqSampleRate,
        channels: kReqChannels,
        format: AudioFormat.Int16,
      ),
    );
    rendererCancels[identity] = cancel;
    log('[renderer] registered for $identity');
  } catch (e, stk) {
    log('[renderer] !!!! addAudioRenderer FAILED for $identity: $e');
    log('[renderer] exceptionType=${e.runtimeType}');
    log('[renderer] $stk');
  }
}

void setUpRoomListeners(Room room) {
  final EventsListener<RoomEvent> listener = room.createListener();
  gListener = listener;

  listener.on<TrackSubscribedEvent>((TrackSubscribedEvent e) {
    final String identity = e.participant.identity;
    log('[event] TrackSubscribed identity=$identity sid=${e.track.sid} kind=${e.track.runtimeType}');
    final bool isAudioTrackMixin = e.track is AudioTrack;
    final bool isRemoteAudio = e.track is RemoteAudioTrack;
    log('[event] TrackSubscribed identity=$identity track is AudioTrack = $isAudioTrackMixin, '
        'track is RemoteAudioTrack = $isRemoteAudio');
    if (isRemoteAudio) {
      attachRenderer(identity, e.track as RemoteAudioTrack);
    } else if (isAudioTrackMixin) {
      attachRenderer(identity, e.track as AudioTrack);
    } else {
      log('[event] identity=$identity track is not audio — skipping renderer');
    }
  });

  listener.on<TrackUnsubscribedEvent>((TrackUnsubscribedEvent e) {
    log('[event] TrackUnsubscribed identity=${e.participant.identity} sid=${e.track.sid} kind=${e.track.runtimeType}');
  });

  listener.on<RoomReconnectingEvent>((RoomReconnectingEvent e) {
    log('[event] RoomReconnecting');
  });

  listener.on<RoomReconnectedEvent>((RoomReconnectedEvent e) {
    log('[event] RoomReconnected');
  });

  listener.on<RoomDisconnectedEvent>((RoomDisconnectedEvent e) {
    log('[event] RoomDisconnected reason=${e.reason}');
  });

  listener.on<RoomConnectedEvent>((RoomConnectedEvent e) {
    log('[event] RoomConnected metadata=${e.metadata}');
  });

  listener.on<ParticipantConnectedEvent>((ParticipantConnectedEvent e) {
    log('[event] ParticipantConnected identity=${e.participant.identity} sid=${e.participant.sid}');
  });

  listener.on<ParticipantDisconnectedEvent>((ParticipantDisconnectedEvent e) {
    log('[event] ParticipantDisconnected identity=${e.participant.identity} sid=${e.participant.sid}');
  });

  listener.on<TrackSubscriptionExceptionEvent>((TrackSubscriptionExceptionEvent e) {
    log('[event] TrackSubscriptionException identity=${e.participant?.identity} sid=${e.sid} reason=${e.reason}');
  });

  listener.on<TrackPublishedEvent>((TrackPublishedEvent e) {
    log('[event] TrackPublished identity=${e.participant.identity} sid=${e.publication.sid} kind=${e.publication.kind}');
  });
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

void startTickers() {
  Timer.periodic(const Duration(seconds: 1), (Timer _) {
    try {
      final Room? room = gRoom;
      log('[tick] room.connectionState=${room?.connectionState} participants=${room?.remoteParticipants.length ?? 0}');
      for (final CaptureState st in captures.values) {
        log('[tick] identity=${st.identity} frames=${st.totalFrames} bytes=${st.totalBytes} '
            'framesThisSec=${st.framesThisSec} bytesThisSec=${st.bytesThisSec}');
        if (st.framesThisSec == 0) {
          log('[tick] identity=${st.identity} STALLED (no frames this second)');
        }
        st.secondBoundaryOffsets.add(st.totalBytes);
        st.framesThisSec = 0;
        st.bytesThisSec = 0;

        // auto-dump once >=10s accumulated (based on reported sample rate)
        final int sr = st.reportedSampleRate > 0 ? st.reportedSampleRate : kReqSampleRate;
        final int ch = st.reportedChannels > 0 ? st.reportedChannels : kReqChannels;
        final int needBytes = sr * ch * 2 * 10;
        if (st.totalBytes - st.autoDumpedAtBytes >= needBytes) {
          st.autoDumpedAtBytes = st.totalBytes;
          log('[auto] 10s threshold reached for ${st.identity} (bytes=${st.totalBytes} need=$needBytes) — firing analyzeAndDump');
          analyzeAndDump(st.identity);
        }
      }
    } catch (e, stk) {
      log('[tick] ERROR: $e');
      log('[tick] $stk');
    }
  });

  Timer.periodic(const Duration(seconds: 2), (Timer _) {
    try {
      final File f = File(kCmdDumpPath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (e) {
          log('[cmd] could not delete CMD_DUMP: $e');
        }
        log('[cmd] dump requested');
        final List<String> ids = captures.keys.toList();
        if (ids.isEmpty) {
          log('[cmd] no known identities to dump');
        }
        for (final String id in ids) {
          analyzeAndDump(id);
        }
        for (final CaptureState st in captures.values) {
          st.reset();
        }
        log('[cmd] buffers reset — fresh capture window begins');
      }
    } catch (e, stk) {
      log('[cmd] ERROR: $e');
      log('[cmd] $stk');
    }
  });
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> runSpike() async {
  log('[boot] spike harness starting');
  log('[boot] outDir=$kOutDir');
  log('[boot] pid=$pid dart=${Platform.version} os=${Platform.operatingSystem} ${Platform.operatingSystemVersion}');

  startTickers();

  tokenCompleter = Completer<Map<String, dynamic>>();
  await connectSignaling();

  log('[boot] waiting for token message...');
  final Map<String, dynamic> tok = await tokenCompleter!.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      log('[boot] !!!! TIMED OUT waiting for token (30s)');
      throw TimeoutException('no token from signaling within 30s');
    },
  );

  final String rawUrl = tok['url'] as String;
  final String token = tok['token'] as String;

  // The already-running signaling server was started when the machine's LAN IP
  // was 172.20.10.13. That address no longer exists on any adapter (current IP
  // is 10.0.0.185), so the URL it hands out is unreachable and room.connect()
  // dies with SocketException errno=121 (semaphore timeout). The LiveKit server
  // itself is bound to 0.0.0.0:7880 and IS reachable on loopback, so rewrite the
  // dead host. The token itself is still the real one minted by signaling.
  String url = rawUrl;
  const String kDeadHost = '172.20.10.13';
  const String kLiveHost = '127.0.0.1';
  if (url.contains(kDeadHost)) {
    url = url.replaceAll(kDeadHost, kLiveHost);
    log('[lk] NOTE: rewrote unreachable signaling-provided host $kDeadHost -> $kLiveHost');
    log('[lk] rawUrl=$rawUrl effectiveUrl=$url');
  }

  log('[lk] creating Room(roomOptions: RoomOptions(adaptiveStream: false, dynacast: false))');
  final Room room = Room(
    roomOptions: const RoomOptions(adaptiveStream: false, dynacast: false),
  );
  gRoom = room;
  setUpRoomListeners(room);

  log('[lk] connecting to $url ...');
  await room.connect(url, token);
  log('[lk] connected. localParticipant=${room.localParticipant?.identity} '
      'state=${room.connectionState} remoteParticipants=${room.remoteParticipants.length}');

  // Attach to already-subscribed tracks (subscribed before our listener ran).
  for (final RemoteParticipant p in room.remoteParticipants.values) {
    log('[lk] existing participant identity=${p.identity} sid=${p.sid} pubs=${p.trackPublications.length}');
    for (final RemoteTrackPublication<RemoteTrack> pub in p.trackPublications.values) {
      final RemoteTrack? t = pub.track;
      log('[lk] existing pub sid=${pub.sid} kind=${pub.kind} subscribed=${pub.subscribed} track=${t.runtimeType}');
      if (t != null && t is AudioTrack) {
        attachRenderer(p.identity, t as AudioTrack);
      }
    }
  }

  log('[boot] setup complete — harness running indefinitely');
}

void main() {
  _prepareOutDir();
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (FlutterErrorDetails details) {
        log('[FLUTTER-ERROR] ${details.exception}');
        log('[FLUTTER-ERROR] ${details.stack}');
      };
      runApp(const SpikeApp());
      runSpike().catchError((Object e, StackTrace st) {
        log('[FATAL] runSpike threw: $e');
        log('[FATAL] type=${e.runtimeType}');
        log('[FATAL] $st');
      });
    },
    (Object error, StackTrace stack) {
      log('[UNCAUGHT] $error');
      log('[UNCAUGHT] type=${error.runtimeType}');
      log('[UNCAUGHT] $stack');
    },
  );
}

// ---------------------------------------------------------------------------
// Trivial UI
// ---------------------------------------------------------------------------

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiveKit PCM Spike',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('LiveKit PCM Spike')),
        body: ValueListenableBuilder<int>(
          valueListenable: logRevision,
          builder: (BuildContext context, int _, Widget? __) {
            final int start = logLines.length > 200 ? logLines.length - 200 : 0;
            final String text = logLines.sublist(start).join('\n');
            return SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              reverse: true,
              child: Text(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            );
          },
        ),
      ),
    );
  }
}
