import 'dart:io';
import 'dart:typed_data';

import 'recording_sink.dart';

/// Streaming G.711 WAV sink (a-law or mu-law, 8 kHz mono, 8-bit).
///
/// Writes the RTP payload **as received** — no decode, no re-encode. This
/// is Phase 2 of the encoding roadmap: bit-for-bit identical to what came
/// off the wire, half the size of the Phase 1 PCM WAV.
///
/// Output layout (58-byte header + N * payload bytes):
///
/// | Offset | Bytes | Field                                    |
/// |-------:|------:|:-----------------------------------------|
/// |      0 |     4 | `"RIFF"`                                 |
/// |      4 |     4 | RIFF chunk size = `50 + dataSize`        |
/// |      8 |     4 | `"WAVE"`                                 |
/// |     12 |     4 | `"fmt "`                                 |
/// |     16 |     4 | fmt sub-chunk size = 18 (non-PCM)        |
/// |     20 |     2 | AudioFormat = 6 (a-law) or 7 (mu-law)    |
/// |     22 |     2 | NumChannels = 1                          |
/// |     24 |     4 | SampleRate = 8000                        |
/// |     28 |     4 | ByteRate = 8000                          |
/// |     32 |     2 | BlockAlign = 1                           |
/// |     34 |     2 | BitsPerSample = 8                        |
/// |     36 |     2 | cbSize = 0                               |
/// |     38 |     4 | `"fact"`                                 |
/// |     42 |     4 | fact sub-chunk size = 4                  |
/// |     46 |     4 | samples-per-channel                      |
/// |     50 |     4 | `"data"`                                 |
/// |     54 |     4 | data sub-chunk size = `dataSize`         |
///
/// The `fact` chunk is required by Microsoft's WAV spec for non-PCM
/// formats; some players (notably Windows Media Player) reject files
/// without it.
class G711WavSink implements RecordingSink {
  G711WavSink._(this._path, this._codec, this._audioFormat, this._expectedPt);

  /// A-law variant. Emits `AudioFormat = 6`; expects RTP `PayloadType = 8`
  /// (PCMA).
  factory G711WavSink.alaw(String path) => G711WavSink._(path, 'alaw', 6, 8);

  /// Mu-law variant. Emits `AudioFormat = 7`; expects RTP `PayloadType = 0`
  /// (PCMU).
  factory G711WavSink.mulaw(String path) => G711WavSink._(path, 'mulaw', 7, 0);

  static const int _sampleRate = 8000;
  static const int _numChannels = 1;
  static const int _bitsPerSample = 8;
  static const int _headerSize = 58;

  final String _path;
  final String _codec;
  final int _audioFormat;
  final int _expectedPt;

  RandomAccessFile? _raf;
  int _dataBytes = 0;
  int _packetCount = 0;
  bool _closed = false;
  int? _ptMismatchWarned;

  @override
  String get codec => _codec;

  @override
  String get container => 'wav';

  @override
  int get sampleRate => _sampleRate;

  @override
  int get numChannels => _numChannels;

  @override
  int get packetCount => _packetCount;

  @override
  int get bytesWritten => _dataBytes;

  @override
  String get path => _path;

  @override
  Duration get duration {
    // 8 kHz * 1 byte/sample * 1 channel = 8000 B/s.
    final bytesPerSec = _sampleRate * _numChannels * (_bitsPerSample ~/ 8);
    if (bytesPerSec == 0) return Duration.zero;
    return Duration(microseconds: _dataBytes * 1000000 ~/ bytesPerSec);
  }

  @override
  Future<void> open() async {
    if (_raf != null) return;
    final file = File(_path);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    // Reserve 58 bytes for the header; patched on close.
    raf.writeFromSync(Uint8List(_headerSize));
    _raf = raf;
  }

  @override
  void write(Uint8List rtpPayload, int payloadType) {
    if (_closed) return;
    final raf = _raf;
    if (raf == null) {
      throw StateError('G711WavSink.write called before open() ($_path)');
    }
    if (payloadType != _expectedPt && _ptMismatchWarned != payloadType) {
      print('G711WavSink($_path): RTP PayloadType=$payloadType does not '
          'match expected $_expectedPt for codec=$_codec; '
          'bytes stored as-is and will be interpreted as $_codec on playback');
      _ptMismatchWarned = payloadType;
    }
    raf.writeFromSync(rtpPayload);
    _dataBytes += rtpPayload.length;
    _packetCount++;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    if (raf == null) return;
    final header = buildG711WavHeader(
      dataSize: _dataBytes,
      audioFormat: _audioFormat,
      sampleRate: _sampleRate,
      numChannels: _numChannels,
    );
    await raf.setPosition(0);
    await raf.writeFrom(header);
    await raf.flush();
    await raf.close();
    _raf = null;
  }

  /// Build a 58-byte G.711 WAV header for the given data payload size.
  /// [audioFormat] must be `6` (a-law) or `7` (mu-law). Exposed for testing.
  static Uint8List buildG711WavHeader({
    required int dataSize,
    required int audioFormat,
    required int sampleRate,
    required int numChannels,
  }) {
    assert(audioFormat == 6 || audioFormat == 7,
        'audioFormat must be 6 (a-law) or 7 (mu-law)');
    final int blockAlign = numChannels * (_bitsPerSample ~/ 8);
    final int byteRate = sampleRate * blockAlign;
    final int samplesPerChannel = blockAlign == 0 ? 0 : dataSize ~/ blockAlign;

    final buf = Uint8List(_headerSize);
    final bd = ByteData.view(buf.buffer);

    // RIFF header.
    _writeAscii(buf, 0, 'RIFF');
    bd.setUint32(4, 50 + dataSize, Endian.little);
    _writeAscii(buf, 8, 'WAVE');

    // fmt chunk (26 bytes: 8-byte header + 18-byte body).
    _writeAscii(buf, 12, 'fmt ');
    bd.setUint32(16, 18, Endian.little); // Subchunk1Size (non-PCM).
    bd.setUint16(20, audioFormat, Endian.little);
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, _bitsPerSample, Endian.little);
    bd.setUint16(36, 0, Endian.little); // cbSize.

    // fact chunk (12 bytes: 8-byte header + 4-byte body).
    _writeAscii(buf, 38, 'fact');
    bd.setUint32(42, 4, Endian.little);
    bd.setUint32(46, samplesPerChannel, Endian.little);

    // data chunk header (8 bytes; data itself follows).
    _writeAscii(buf, 50, 'data');
    bd.setUint32(54, dataSize, Endian.little);

    return buf;
  }

  static void _writeAscii(Uint8List b, int off, String s) {
    for (int i = 0; i < s.length; i++) {
      b[off + i] = s.codeUnitAt(i);
    }
  }
}
