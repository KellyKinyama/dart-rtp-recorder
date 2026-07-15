import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/recorder/g711_wav_sink.dart';
import 'package:test/test.dart';

Uint8List _fakePacket(int n, int seed) {
  final b = Uint8List(n);
  for (int i = 0; i < n; i++) {
    b[i] = (seed + i * 3) & 0xff;
  }
  return b;
}

int _u16le(Uint8List b, int off) => b[off] | (b[off + 1] << 8);
int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
String _ascii(Uint8List b, int off, int len) =>
    String.fromCharCodes(b.sublist(off, off + len));

void _assertG711Header(
  Uint8List bytes, {
  required int expectedAudioFormat,
  required int expectedDataSize,
}) {
  expect(bytes.length, 58 + expectedDataSize, reason: 'total file length');
  expect(_ascii(bytes, 0, 4), 'RIFF');
  expect(_u32le(bytes, 4), 50 + expectedDataSize, reason: 'RIFF chunk size');
  expect(_ascii(bytes, 8, 4), 'WAVE');
  expect(_ascii(bytes, 12, 4), 'fmt ');
  expect(_u32le(bytes, 16), 18, reason: 'fmt subchunk size (non-PCM)');
  expect(_u16le(bytes, 20), expectedAudioFormat, reason: 'AudioFormat');
  expect(_u16le(bytes, 22), 1, reason: 'NumChannels');
  expect(_u32le(bytes, 24), 8000, reason: 'SampleRate');
  expect(_u32le(bytes, 28), 8000, reason: 'ByteRate (= 8000 for 8-bit mono)');
  expect(_u16le(bytes, 32), 1, reason: 'BlockAlign');
  expect(_u16le(bytes, 34), 8, reason: 'BitsPerSample');
  expect(_u16le(bytes, 36), 0, reason: 'cbSize');
  expect(_ascii(bytes, 38, 4), 'fact');
  expect(_u32le(bytes, 42), 4, reason: 'fact subchunk size');
  expect(_u32le(bytes, 46), expectedDataSize,
      reason: 'samples-per-channel = dataSize for 8-bit');
  expect(_ascii(bytes, 50, 4), 'data');
  expect(_u32le(bytes, 54), expectedDataSize, reason: 'data subchunk size');
}

void main() {
  group('G711WavSink', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('g711_wav_sink_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a-law: correct header, bytes stored verbatim, no expansion',
        () async {
      final path = '${tmp.path}/alaw.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();

      final p1 = _fakePacket(160, 1);
      final p2 = _fakePacket(160, 2);
      final p3 = _fakePacket(160, 3);
      sink.write(p1, 8);
      sink.write(p2, 8);
      sink.write(p3, 8);
      await sink.close();

      final bytes = File(path).readAsBytesSync();
      _assertG711Header(bytes, expectedAudioFormat: 6, expectedDataSize: 480);

      // Payload passthrough (no G.711 decode, no PCM expansion).
      expect(bytes.sublist(58, 58 + 160), p1);
      expect(bytes.sublist(58 + 160, 58 + 320), p2);
      expect(bytes.sublist(58 + 320, 58 + 480), p3);

      expect(sink.codec, 'alaw');
      expect(sink.container, 'wav');
      expect(sink.packetCount, 3);
      expect(sink.bytesWritten, 480);
      // 480 bytes / 8000 B/s = 60 ms.
      expect(sink.duration, const Duration(milliseconds: 60));
    });

    test('mu-law: audio format code = 7 and codec label = "mulaw"', () async {
      final path = '${tmp.path}/mulaw.wav';
      final sink = G711WavSink.mulaw(path);
      await sink.open();
      sink.write(_fakePacket(160, 0), 0);
      await sink.close();

      final bytes = File(path).readAsBytesSync();
      _assertG711Header(bytes, expectedAudioFormat: 7, expectedDataSize: 160);
      expect(sink.codec, 'mulaw');
    });

    test('half the size of PCM WAV for the same call', () async {
      // A 1-second call is 8000 a-law bytes vs. 16000 PCM bytes; the WAV
      // container is a fixed 58 vs. 44 header, so the ratio is
      // effectively 2x for anything of realistic length.
      final path = '${tmp.path}/onesec.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();
      // 50 packets * 160 bytes = 8000 bytes = 1 s of a-law.
      for (int i = 0; i < 50; i++) {
        sink.write(_fakePacket(160, i), 8);
      }
      await sink.close();

      final size = File(path).lengthSync();
      expect(size, 58 + 8000);
      // Corresponding PCM WAV would be 44 + 16000 = 16044 bytes; a-law is
      // (58 + 8000) / 16044 ≈ 0.502 — the phase 2 halving claim.
      expect(size / 16044, lessThan(0.51));
      expect(sink.duration, const Duration(seconds: 1));
    });

    test('empty recording still yields a valid WAV', () async {
      final path = '${tmp.path}/empty.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();
      await sink.close();

      final bytes = File(path).readAsBytesSync();
      _assertG711Header(bytes, expectedAudioFormat: 6, expectedDataSize: 0);
    });

    test('double close is a no-op', () async {
      final path = '${tmp.path}/double.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();
      sink.write(_fakePacket(160, 0), 8);
      await sink.close();
      await sink.close();
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 58 + 160);
    });

    test('write after close is a defensive no-op', () async {
      final path = '${tmp.path}/postclose.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();
      sink.write(_fakePacket(160, 0), 8);
      await sink.close();
      sink.write(_fakePacket(160, 1), 8); // must not throw or extend file
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 58 + 160);
    });

    test('PT mismatch still stores bytes but logs (verified by counters)',
        () async {
      final path = '${tmp.path}/mismatch.wav';
      final sink = G711WavSink.alaw(path);
      await sink.open();
      // PT=0 (mu-law) sent to a-law sink — bytes still stored as-is.
      sink.write(_fakePacket(160, 0), 0);
      await sink.close();
      expect(sink.packetCount, 1);
      expect(sink.bytesWritten, 160);
    });

    test('buildG711WavHeader is byte-exact for a known size (a-law)', () {
      final h = G711WavSink.buildG711WavHeader(
        dataSize: 480,
        audioFormat: 6,
        sampleRate: 8000,
        numChannels: 1,
      );
      expect(h.length, 58);
      expect(_ascii(h, 0, 4), 'RIFF');
      expect(_u32le(h, 4), 50 + 480);
      expect(_ascii(h, 8, 4), 'WAVE');
      expect(_ascii(h, 12, 4), 'fmt ');
      expect(_u32le(h, 16), 18);
      expect(_u16le(h, 20), 6);
      expect(_u16le(h, 22), 1);
      expect(_u32le(h, 24), 8000);
      expect(_u32le(h, 28), 8000);
      expect(_u16le(h, 32), 1);
      expect(_u16le(h, 34), 8);
      expect(_u16le(h, 36), 0);
      expect(_ascii(h, 38, 4), 'fact');
      expect(_u32le(h, 42), 4);
      expect(_u32le(h, 46), 480);
      expect(_ascii(h, 50, 4), 'data');
      expect(_u32le(h, 54), 480);
    });
  });
}
