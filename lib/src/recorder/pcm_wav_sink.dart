import 'dart:io';
import 'dart:typed_data';

import '../codecs/g711/dart_g711.dart';
import 'recording_sink.dart';

/// Streaming 16-bit PCM WAV sink (8 kHz mono).
///
/// Writes a 44-byte RIFF header placeholder on [open], streams decoded PCM
/// to disk via `RandomAccessFile.writeFromSync` on every RTP packet, and
/// patches the RIFF chunk-size + `data` sub-chunk-size on [close].
///
/// Memory footprint per open recording: one file handle + one 320-byte
/// PCM buffer per packet (immediately GC'd). Replaces the previous
/// whole-call `List<Uint8List>` + boxed `List<int>` flatten in
/// `rtp_server.dart` which peaked at hundreds of MiB per call.
class PcmWavSink implements RecordingSink {
  PcmWavSink(this._path);

  static const int _sampleRate = 8000;
  static const int _numChannels = 1;
  static const int _bytesPerSample = 2;
  static const int _headerSize = 44;

  final String _path;
  final DartG711Codec _alaw = DartG711Codec.g711a();
  final DartG711Codec _ulaw = DartG711Codec.g711u();

  RandomAccessFile? _raf;
  int _dataBytes = 0;
  int _packetCount = 0;
  bool _closed = false;
  int? _unknownPtWarned;

  @override
  String get codec => 'pcm_s16le';

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
    final bytesPerSec = _sampleRate * _numChannels * _bytesPerSample;
    if (bytesPerSec == 0) return Duration.zero;
    return Duration(microseconds: _dataBytes * 1000000 ~/ bytesPerSec);
  }

  @override
  Future<void> open() async {
    if (_raf != null) return;
    final file = File(_path);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    // Reserve 44 bytes for the RIFF header; patched on close.
    raf.writeFromSync(Uint8List(_headerSize));
    _raf = raf;
  }

  @override
  void write(Uint8List rtpPayload, int payloadType) {
    if (_closed) return;
    final raf = _raf;
    if (raf == null) {
      throw StateError('PcmWavSink.write called before open() ($_path)');
    }

    final DartG711Codec c;
    switch (payloadType) {
      case 0: // PCMU / mu-law
        c = _ulaw;
        break;
      case 8: // PCMA / a-law
        c = _alaw;
        break;
      default:
        if (_unknownPtWarned != payloadType) {
          print('PcmWavSink($_path): RTP PayloadType=$payloadType '
              'is not G.711; assuming a-law');
          _unknownPtWarned = payloadType;
        }
        c = _alaw;
    }

    final pcm = c.decode(rtpPayload);
    raf.writeFromSync(pcm);
    _dataBytes += pcm.length;
    _packetCount++;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    if (raf == null) return;

    final header = buildRiffHeader(
      dataSize: _dataBytes,
      sampleRate: _sampleRate,
      numChannels: _numChannels,
      bytesPerSample: _bytesPerSample,
    );
    await raf.setPosition(0);
    await raf.writeFrom(header);
    await raf.flush();
    await raf.close();
    _raf = null;
  }

  /// Build a 44-byte canonical RIFF/WAVE PCM header for the given data
  /// payload size (in bytes). Exposed for testing.
  static Uint8List buildRiffHeader({
    required int dataSize,
    required int sampleRate,
    required int numChannels,
    required int bytesPerSample,
  }) {
    final byteRate = sampleRate * numChannels * bytesPerSample;
    final blockAlign = numChannels * bytesPerSample;
    final buf = Uint8List(_headerSize);
    final bd = ByteData.view(buf.buffer);

    // "RIFF"
    buf[0] = 0x52;
    buf[1] = 0x49;
    buf[2] = 0x46;
    buf[3] = 0x46;
    bd.setUint32(4, 36 + dataSize, Endian.little);
    // "WAVE"
    buf[8] = 0x57;
    buf[9] = 0x41;
    buf[10] = 0x56;
    buf[11] = 0x45;
    // "fmt "
    buf[12] = 0x66;
    buf[13] = 0x6d;
    buf[14] = 0x74;
    buf[15] = 0x20;
    bd.setUint32(16, 16, Endian.little); // Subchunk1Size (PCM)
    bd.setUint16(20, 1, Endian.little); // AudioFormat = PCM
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bytesPerSample * 8, Endian.little);
    // "data"
    buf[36] = 0x64;
    buf[37] = 0x61;
    buf[38] = 0x74;
    buf[39] = 0x61;
    bd.setUint32(40, dataSize, Endian.little);
    return buf;
  }
}
