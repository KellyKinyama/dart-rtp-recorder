import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/recorder/pcm_wav_sink.dart';
import 'package:test/test.dart';

/// Build a synthetic G.711 a-law payload of [n] bytes.
Uint8List _fakeAlawPacket(int n, int seed) {
  final b = Uint8List(n);
  for (int i = 0; i < n; i++) {
    b[i] = (seed + i) & 0xff;
  }
  return b;
}

int _u16le(Uint8List b, int off) => b[off] | (b[off + 1] << 8);
int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

String _ascii(Uint8List b, int off, int len) =>
    String.fromCharCodes(b.sublist(off, off + len));

void main() {
  group('PcmWavSink', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pcm_wav_sink_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writes a valid 44-byte RIFF header and correct data length',
        () async {
      final path = '${tmp.path}/rec.wav';
      final sink = PcmWavSink(path);
      await sink.open();

      // 3 packets of 160 bytes each = 3 * 160 = 480 a-law bytes.
      // After G.711 -> 16-bit PCM decode: 3 * 320 = 960 PCM bytes.
      const packetCount = 3;
      const payloadSize = 160;
      for (int i = 0; i < packetCount; i++) {
        sink.write(_fakeAlawPacket(payloadSize, i * 17), 8 /* PCMA */);
      }
      await sink.close();

      final bytes = File(path).readAsBytesSync();
      const expectedData = packetCount * payloadSize * 2; // 960
      const expectedTotal = 44 + expectedData; // 1004

      expect(bytes.length, expectedTotal, reason: 'total file length');
      expect(_ascii(bytes, 0, 4), 'RIFF');
      expect(_u32le(bytes, 4), 36 + expectedData, reason: 'RIFF chunk size');
      expect(_ascii(bytes, 8, 4), 'WAVE');
      expect(_ascii(bytes, 12, 4), 'fmt ');
      expect(_u32le(bytes, 16), 16, reason: 'fmt subchunk size');
      expect(_u16le(bytes, 20), 1, reason: 'AudioFormat=PCM');
      expect(_u16le(bytes, 22), 1, reason: 'NumChannels=1');
      expect(_u32le(bytes, 24), 8000, reason: 'SampleRate');
      expect(_u32le(bytes, 28), 16000, reason: 'ByteRate = 8000*1*2');
      expect(_u16le(bytes, 32), 2, reason: 'BlockAlign = 1*2');
      expect(_u16le(bytes, 34), 16, reason: 'BitsPerSample');
      expect(_ascii(bytes, 36, 4), 'data');
      expect(_u32le(bytes, 40), expectedData, reason: 'data subchunk size');

      expect(sink.packetCount, packetCount);
      expect(sink.bytesWritten, expectedData);
      // 960 bytes / (8000 * 2 * 1 = 16000 B/s) = 60 ms.
      expect(sink.duration, const Duration(milliseconds: 60));
      expect(sink.codec, 'pcm_s16le');
      expect(sink.container, 'wav');
    });

    test('empty recording still yields a valid WAV', () async {
      final path = '${tmp.path}/empty.wav';
      final sink = PcmWavSink(path);
      await sink.open();
      await sink.close();

      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 44);
      expect(_ascii(bytes, 0, 4), 'RIFF');
      expect(_u32le(bytes, 4), 36, reason: 'chunk size = 36 for empty data');
      expect(_ascii(bytes, 8, 4), 'WAVE');
      expect(_u32le(bytes, 40), 0, reason: 'data subchunk size = 0');
    });

    test('double close is a no-op', () async {
      final path = '${tmp.path}/double.wav';
      final sink = PcmWavSink(path);
      await sink.open();
      sink.write(_fakeAlawPacket(160, 0), 8);
      await sink.close();
      await sink.close(); // must not throw
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 44 + 320);
    });

    test('write after close is a no-op (does not throw)', () async {
      final path = '${tmp.path}/postclose.wav';
      final sink = PcmWavSink(path);
      await sink.open();
      sink.write(_fakeAlawPacket(160, 0), 8);
      await sink.close();
      // After close, write is defensively swallowed.
      sink.write(_fakeAlawPacket(160, 1), 8);
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 44 + 320,
          reason: 'post-close writes must not extend the file');
    });

    test('buildRiffHeader is byte-exact for a known size', () {
      final h = PcmWavSink.buildRiffHeader(
        dataSize: 960,
        sampleRate: 8000,
        numChannels: 1,
        bytesPerSample: 2,
      );
      expect(h.length, 44);
      expect(_ascii(h, 0, 4), 'RIFF');
      expect(_u32le(h, 4), 36 + 960);
      expect(_ascii(h, 8, 4), 'WAVE');
      expect(_ascii(h, 12, 4), 'fmt ');
      expect(_u32le(h, 16), 16);
      expect(_u16le(h, 20), 1);
      expect(_u16le(h, 22), 1);
      expect(_u32le(h, 24), 8000);
      expect(_u32le(h, 28), 16000);
      expect(_u16le(h, 32), 2);
      expect(_u16le(h, 34), 16);
      expect(_ascii(h, 36, 4), 'data');
      expect(_u32le(h, 40), 960);
    });
  });
}
