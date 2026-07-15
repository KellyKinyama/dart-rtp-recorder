import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/codecs/g711/dart_g711.dart';
import 'package:dart_rtp_recorder/src/http/playback.dart';
import 'package:dart_rtp_recorder/src/recorder/g711_wav_sink.dart';
import 'package:dart_rtp_recorder/src/recorder/pcm_wav_sink.dart';
import 'package:dart_rtp_recorder/src/recorder/rtp_server.dart' as recorder;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

int _u32le(List<int> b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

Uint8List _fakePayload(int n, int seed) {
  final b = Uint8List(n);
  for (int i = 0; i < n; i++) {
    b[i] = (seed + i * 3) & 0xff;
  }
  return b;
}

Future<void> _writeAlawFile(String path, List<Uint8List> payloads) async {
  final sink = G711WavSink.alaw(path);
  await sink.open();
  for (final p in payloads) {
    sink.write(p, 8);
  }
  await sink.close();
}

Future<Uint8List> _readAll(HttpClientResponse resp) async {
  final b = BytesBuilder();
  await for (final c in resp) {
    b.add(c);
  }
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// Range parser tests
// ---------------------------------------------------------------------------

void _rangeTests() {
  group('parseRange', () {
    test('null header -> full file', () {
      final r = parseRange(null, 1000);
      expect(r.satisfiable, true);
      expect(r.partial, false);
      expect(r.start, 0);
      expect(r.end, 999);
      expect(r.length, 1000);
    });

    test('bytes=0-499', () {
      final r = parseRange('bytes=0-499', 1000);
      expect(r.satisfiable, true);
      expect(r.partial, true);
      expect(r.start, 0);
      expect(r.end, 499);
      expect(r.length, 500);
    });

    test('bytes=500- (open-ended)', () {
      final r = parseRange('bytes=500-', 1000);
      expect(r.satisfiable, true);
      expect(r.partial, true);
      expect(r.start, 500);
      expect(r.end, 999);
      expect(r.length, 500);
    });

    test('bytes=-100 (suffix)', () {
      final r = parseRange('bytes=-100', 1000);
      expect(r.satisfiable, true);
      expect(r.partial, true);
      expect(r.start, 900);
      expect(r.end, 999);
      expect(r.length, 100);
    });

    test('bytes=0- covering full file is NOT partial', () {
      final r = parseRange('bytes=0-999', 1000);
      expect(r.satisfiable, true);
      expect(r.partial, false);
    });

    test('bytes past EOF -> unsatisfiable', () {
      final r = parseRange('bytes=5000-6000', 1000);
      expect(r.satisfiable, false);
    });

    test('malformed header -> full file', () {
      final r = parseRange('bytes=abc-def', 1000);
      expect(r.satisfiable, true);
      expect(r.partial, false);
      expect(r.length, 1000);
    });

    test('end clamped to EOF', () {
      final r = parseRange('bytes=990-5000', 1000);
      expect(r.satisfiable, true);
      expect(r.start, 990);
      expect(r.end, 999);
    });

    test('zero-length file -> unsatisfiable', () {
      final r = parseRange(null, 0);
      expect(r.satisfiable, false);
    });
  });
}

// ---------------------------------------------------------------------------
// WAV info parser tests
// ---------------------------------------------------------------------------

void _wavInfoTests(Directory tmp) {
  group('readWavInfo', () {
    test('parses a G.711 a-law WAV written by G711WavSink', () async {
      final path = '${tmp.path}/parse-alaw.wav';
      await _writeAlawFile(path, [_fakePayload(160, 1), _fakePayload(160, 2)]);
      final raf = await File(path).open();
      try {
        final info = await readWavInfo(raf);
        expect(info.audioFormat, 6);
        expect(info.isAlaw, true);
        expect(info.isG711, true);
        expect(info.isPcm, false);
        expect(info.numChannels, 1);
        expect(info.sampleRate, 8000);
        expect(info.bitsPerSample, 8);
        expect(info.dataOffset, 58);
        expect(info.dataSize, 320);
      } finally {
        await raf.close();
      }
    });

    test('parses a PCM WAV written by PcmWavSink', () async {
      final path = '${tmp.path}/parse-pcm.wav';
      final sink = PcmWavSink(path);
      await sink.open();
      sink.write(_fakePayload(160, 3), 8);
      await sink.close();
      final raf = await File(path).open();
      try {
        final info = await readWavInfo(raf);
        expect(info.audioFormat, 1);
        expect(info.isPcm, true);
        expect(info.isG711, false);
        expect(info.dataOffset, 44);
        expect(info.dataSize, 320);
      } finally {
        await raf.close();
      }
    });

    test('rejects a non-RIFF file', () async {
      final path = '${tmp.path}/not-riff.bin';
      File(path).writeAsBytesSync(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]));
      final raf = await File(path).open();
      try {
        // Must be expectLater — `expect(fn, throwsA(...))` on an async
        // function will not subscribe synchronously and the pending read
        // op collides with raf.close() below.
        await expectLater(readWavInfo(raf), throwsA(isA<FormatException>()));
      } finally {
        await raf.close();
      }
    });
  });
}

// ---------------------------------------------------------------------------
// streamTranscodedPcmRange tests
// ---------------------------------------------------------------------------

Uint8List _decodeAllAlawToPcmWav(Uint8List alawWav) {
  // Assume header layout produced by G711WavSink (dataOffset=58, dataSize
  // in fmt chunk). Decode entire body via a-law codec, then wrap in PCM
  // header via PcmWavSink.buildRiffHeader — this is the ground truth for
  // full-file transcode.
  final dataSize = _u32le(alawWav, 54);
  final body = Uint8List.sublistView(alawWav, 58, 58 + dataSize);
  final pcm = DartG711Codec.g711a().decode(body);
  final header = PcmWavSink.buildRiffHeader(
    dataSize: pcm.length,
    sampleRate: 8000,
    numChannels: 1,
    bytesPerSample: 2,
  );
  final out = Uint8List(header.length + pcm.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, pcm);
  return out;
}

void _streamTests(Directory tmp) {
  group('streamTranscodedPcmRange', () {
    test('full-range output equals ground-truth PCM WAV', () async {
      final path = '${tmp.path}/full.wav';
      await _writeAlawFile(path, [
        _fakePayload(160, 1),
        _fakePayload(160, 2),
        _fakePayload(160, 3),
      ]);
      final srcBytes = File(path).readAsBytesSync();
      final expected = _decodeAllAlawToPcmWav(srcBytes);

      final raf = await File(path).open();
      try {
        final info = await readWavInfo(raf);
        final out = <int>[];
        await for (final chunk in streamTranscodedPcmRange(
          srcRaf: raf,
          info: info,
          codec: DartG711Codec.g711a(),
          outStart: 0,
          outEnd: 44 + 2 * info.dataSize - 1,
        )) {
          out.addAll(chunk);
        }
        expect(out.length, expected.length);
        expect(Uint8List.fromList(out), expected);
      } finally {
        await raf.close();
      }
    });

    test('partial body range matches the same slice of the full output',
        () async {
      final path = '${tmp.path}/partial.wav';
      await _writeAlawFile(path, [
        _fakePayload(160, 10),
        _fakePayload(160, 20),
      ]);
      final expected = _decodeAllAlawToPcmWav(File(path).readAsBytesSync());

      // Pick an odd start so we exercise the `trimFront` branch, and an
      // even end so we exercise `trimBack`.
      const start = 45; // one byte into the PCM body, mid-sample
      const end = 200;
      final raf = await File(path).open();
      try {
        final info = await readWavInfo(raf);
        final out = <int>[];
        await for (final chunk in streamTranscodedPcmRange(
          srcRaf: raf,
          info: info,
          codec: DartG711Codec.g711a(),
          outStart: start,
          outEnd: end,
        )) {
          out.addAll(chunk);
        }
        expect(out.length, end - start + 1);
        expect(Uint8List.fromList(out),
            Uint8List.sublistView(expected, start, end + 1));
      } finally {
        await raf.close();
      }
    });

    test('header-only range (bytes 0-43) returns just the PCM header',
        () async {
      final path = '${tmp.path}/hdr.wav';
      await _writeAlawFile(path, [_fakePayload(160, 1)]);
      final expected = _decodeAllAlawToPcmWav(File(path).readAsBytesSync());

      final raf = await File(path).open();
      try {
        final info = await readWavInfo(raf);
        final out = <int>[];
        await for (final chunk in streamTranscodedPcmRange(
          srcRaf: raf,
          info: info,
          codec: DartG711Codec.g711a(),
          outStart: 0,
          outEnd: 43,
        )) {
          out.addAll(chunk);
        }
        expect(out.length, 44);
        expect(Uint8List.fromList(out), Uint8List.sublistView(expected, 0, 44));
      } finally {
        await raf.close();
      }
    });
  });
}

// ---------------------------------------------------------------------------
// End-to-end playbackRecording tests (real HttpServer on 127.0.0.1)
// ---------------------------------------------------------------------------

Future<HttpServer> _spinUpServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    // Only /playback is exercised in these tests.
    if (req.uri.path == '/playback') {
      final fn = req.uri.queryParameters['filename'] ?? '';
      await playbackRecording(fn, req);
    } else {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    }
  });
  return server;
}

Future<HttpClientResponse> _get(
  int port,
  String path, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    headers.forEach((k, v) => req.headers.set(k, v));
    return await req.close();
  } finally {
    client.close(force: false);
  }
}

void _endToEndTests(Directory tmp) {
  group('playbackRecording HTTP end-to-end', () {
    late HttpServer server;
    late String cacheDir;
    late String origAudio;
    late bool origCacheEnabled;
    late String origCachePath;

    setUp(() async {
      origAudio = recorder.audioPath;
      origCacheEnabled = playbackCacheEnabled;
      origCachePath = playbackCachePath;
      recorder.audioPath = tmp.path;
      cacheDir = '${tmp.path}/.pcm-cache';
      playbackCacheEnabled = true;
      playbackCachePath = cacheDir;
      server = await _spinUpServer();
    });

    tearDown(() async {
      await server.close(force: true);
      recorder.audioPath = origAudio;
      playbackCacheEnabled = origCacheEnabled;
      playbackCachePath = origCachePath;
    });

    test('404 for missing file', () async {
      final resp = await _get(server.port, '/playback?filename=nope');
      expect(resp.statusCode, 404);
      final body = utf8.decode(await _readAll(resp));
      expect(body, contains('no such recording'));
    });

    test('a-law source -> 200 audio/wav with correct PCM body', () async {
      await _writeAlawFile('${tmp.path}/call1.wav', [
        _fakePayload(160, 1),
        _fakePayload(160, 2),
      ]);
      final srcBytes = File('${tmp.path}/call1.wav').readAsBytesSync();
      final expected = _decodeAllAlawToPcmWav(srcBytes);

      final resp = await _get(server.port,
          '/playback?filename=call1&cache=0'); // no cache side-effects
      expect(resp.statusCode, 200);
      expect(resp.headers.contentType?.mimeType, 'audio/wav');
      expect(resp.headers.value('accept-ranges'), 'bytes');
      expect(resp.contentLength, expected.length);
      final body = await _readAll(resp);
      expect(body, expected);
    });

    test('a-law source with Range -> 206 partial content', () async {
      await _writeAlawFile('${tmp.path}/call2.wav', [
        _fakePayload(160, 10),
        _fakePayload(160, 20),
        _fakePayload(160, 30),
      ]);
      final expected = _decodeAllAlawToPcmWav(
          File('${tmp.path}/call2.wav').readAsBytesSync());

      final resp = await _get(
        server.port,
        '/playback?filename=call2&cache=0',
        headers: {'range': 'bytes=100-299'},
      );
      expect(resp.statusCode, 206);
      final total = expected.length;
      expect(resp.headers.value('content-range'), 'bytes 100-299/$total');
      expect(resp.contentLength, 200);
      final body = await _readAll(resp);
      expect(body, Uint8List.sublistView(expected, 100, 300));
    });

    test('a-law source populates cache; second request served from cache',
        () async {
      await _writeAlawFile('${tmp.path}/call3.wav', [
        _fakePayload(160, 100),
        _fakePayload(160, 101),
      ]);
      final expected = _decodeAllAlawToPcmWav(
          File('${tmp.path}/call3.wav').readAsBytesSync());

      // First request: cache miss — streamed transcode + background populate.
      final r1 = await _get(server.port, '/playback?filename=call3');
      expect(r1.statusCode, 200);
      final body1 = await _readAll(r1);
      expect(body1, expected);

      // Wait for the background populate to finish. Poll up to 3 s.
      final cached = File('$cacheDir/call3.pcm.wav');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!cached.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(cached.existsSync(), true,
          reason: 'background cache populate should have written the file');
      expect(cached.readAsBytesSync(), expected,
          reason: 'cached PCM WAV must be byte-identical to the streamed one');

      // Delete the SOURCE. If the second request still succeeds with the
      // same body, we proved the cache-hit path was taken (the source
      // isn't there any more, so on-the-fly decode would have 404'd).
      File('${tmp.path}/call3.wav').deleteSync();
      final r2 = await _get(server.port, '/playback?filename=call3');
      expect(r2.statusCode, 200,
          reason: 'cache should be served even without the source');
      final body2 = await _readAll(r2);
      expect(body2, expected);
    });

    test('cache=0 opt-out skips populate', () async {
      await _writeAlawFile('${tmp.path}/call4.wav', [_fakePayload(160, 1)]);
      final r = await _get(server.port, '/playback?filename=call4&cache=0');
      expect(r.statusCode, 200);
      await _readAll(r);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File('$cacheDir/call4.pcm.wav').existsSync(), false);
    });

    test('PCM source is sent through directly (no transcode)', () async {
      final sink = PcmWavSink('${tmp.path}/call5.wav');
      await sink.open();
      sink.write(_fakePayload(160, 7), 8);
      await sink.close();
      final expected = File('${tmp.path}/call5.wav').readAsBytesSync();

      final r = await _get(server.port, '/playback?filename=call5');
      expect(r.statusCode, 200);
      expect(r.contentLength, expected.length);
      final body = await _readAll(r);
      expect(body, expected);
    });
  });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void main() {
  _rangeTests();

  final tmp = Directory.systemTemp.createTempSync('playback_test_');
  tearDownAll(() async {
    // Windows may still hold handles briefly after HttpServer.close and
    // background cache-populate tasks. Retry a few times before giving up
    // — a leftover temp dir is harmless (OS cleanup will get it).
    for (var i = 0; i < 10; i++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  _wavInfoTests(tmp);
  _streamTests(tmp);
  _endToEndTests(tmp);
}
