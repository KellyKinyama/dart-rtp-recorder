import 'dart:typed_data';

/// Streaming sink for a single call recording.
///
/// A [RecordingSink] is created once per call, [open]ed, fed one RTP payload
/// at a time via [write], and finally [close]d. Implementations MUST NOT
/// buffer the entire call in memory — instead they stream to disk (or wire)
/// as data arrives so peak RAM per call stays small and the process can
/// sustain 30+ concurrent recordings.
///
/// Phase 0 ships a single implementation: [PcmWavSink] (16-bit PCM WAV).
/// Later phases plug in `AlawWavSink` and `OpusOggSink` behind the same
/// interface — the RTP receive path never has to know the difference.
abstract class RecordingSink {
  /// Codec identifier persisted to the DB (e.g. `pcm_s16le`, `alaw`,
  /// `mulaw`, `opus`).
  String get codec;

  /// Container identifier persisted to the DB (e.g. `wav`, `ogg`, `raw`).
  String get container;

  /// Sample rate of the recorded audio, in Hz.
  int get sampleRate;

  /// Number of channels (currently always 1 for telephony).
  int get numChannels;

  /// Count of RTP payloads written so far.
  int get packetCount;

  /// Total bytes of on-disk payload data (not counting container headers).
  int get bytesWritten;

  /// Duration of the audio recorded so far.
  Duration get duration;

  /// Absolute path of the file backing this sink.
  String get path;

  /// Open the underlying file / encoder. Must be called before [write].
  Future<void> open();

  /// Write one RTP payload. `payloadType` is the RTP PT (0 = PCMU/mu-law,
  /// 8 = PCMA/a-law). This method must not block the event loop on disk I/O
  /// for a meaningful duration — implementations should write small chunks
  /// synchronously (e.g. `RandomAccessFile.writeFromSync`).
  void write(Uint8List rtpPayload, int payloadType);

  /// Finalize the recording: patch container headers, flush, close file.
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<void> close();
}

/// Result of a completed recording, returned from the `/stop` endpoint and
/// used to populate the DB row.
class RecordingResult {
  RecordingResult({
    required this.filename,
    required this.path,
    required this.codec,
    required this.container,
    required this.sampleRate,
    required this.packetCount,
    required this.bytesWritten,
    required this.duration,
  });

  final String filename;
  final String path;
  final String codec;
  final String container;
  final int sampleRate;
  final int packetCount;
  final int bytesWritten;
  final Duration duration;

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'path': path,
        'codec': codec,
        'container': container,
        'sample_rate': sampleRate,
        'packet_count': packetCount,
        'bytes': bytesWritten,
        'duration_ms': duration.inMilliseconds,
      };
}
