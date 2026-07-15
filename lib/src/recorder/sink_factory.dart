import 'g711_wav_sink.dart';
import 'pcm_wav_sink.dart';
import 'recording_sink.dart';

/// Build a [RecordingSink] for the given filesystem [path], selecting the
/// implementation based on [codec].
///
/// Supported values (case-insensitive):
///   * `pcm`, `pcm_s16le`, `wav` — [PcmWavSink] (Phase 1, default).
///   * `alaw`                     — [G711WavSink.alaw]  (Phase 2).
///   * `mulaw`, `ulaw`, `pcmu`    — [G711WavSink.mulaw] (Phase 2).
///
/// Reserved for later phases (throws until implemented):
///   * `opus` — Opus in Ogg (Phase 3).
RecordingSink createRecordingSink(String path, {required String codec}) {
  switch (codec.toLowerCase()) {
    case 'pcm':
    case 'pcm_s16le':
    case 'wav':
      return PcmWavSink(path);
    case 'alaw':
    case 'pcma':
      return G711WavSink.alaw(path);
    case 'mulaw':
    case 'ulaw':
    case 'pcmu':
      return G711WavSink.mulaw(path);
    case 'opus':
      throw UnimplementedError(
        'RECORDER_CODEC="opus" is reserved for Phase 3 and not yet '
        'implemented. Use "pcm", "alaw", or "mulaw" for now.',
      );
    default:
      throw ArgumentError.value(
        codec,
        'codec',
        'Unsupported RECORDER_CODEC. Supported: pcm '
            '(aliases: pcm_s16le, wav), alaw (alias: pcma), '
            'mulaw (aliases: ulaw, pcmu).',
      );
  }
}
