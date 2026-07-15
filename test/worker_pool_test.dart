import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/recorder/worker_pool.dart';
import 'package:test/test.dart';

/// Build a minimal PCMA (payload type 8) RTP packet with [payload] bytes.
Uint8List _rtpPacket({
  required int sequence,
  required int timestamp,
  required int ssrc,
  required Uint8List payload,
}) {
  final b = BytesBuilder();
  b.addByte(0x80); // V=2, P=0, X=0, CC=0
  b.addByte(0x08); // M=0, PT=8 (PCMA)
  b.addByte((sequence >> 8) & 0xFF);
  b.addByte(sequence & 0xFF);
  b.addByte((timestamp >> 24) & 0xFF);
  b.addByte((timestamp >> 16) & 0xFF);
  b.addByte((timestamp >> 8) & 0xFF);
  b.addByte(timestamp & 0xFF);
  b.addByte((ssrc >> 24) & 0xFF);
  b.addByte((ssrc >> 16) & 0xFF);
  b.addByte((ssrc >> 8) & 0xFF);
  b.addByte(ssrc & 0xFF);
  b.add(payload);
  return b.toBytes();
}

/// Wait until [predicate] is true or [timeout] elapses. Polls every 20 ms.
Future<bool> _waitFor(bool Function() predicate,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return predicate();
}

void main() {
  group('RecorderWorkerPool', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pool_test_');
      await RecorderWorkerPool.reset();
    });

    tearDown(() async {
      await RecorderWorkerPool.reset();
      // Windows can hold onto WAVs for a beat after the isolate closes
      // them; retry a few times before giving up.
      for (var i = 0; i < 5; i++) {
        try {
          await tmp.delete(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    test('records G.711 payloads received over UDP through a worker isolate',
        () async {
      await RecorderWorkerPool.initialize(
        mode: WorkerMode.isolated,
        workerCount: 1,
      );
      final pool = RecorderWorkerPool.instance!;

      final outcome = await pool.start(
        filename: 'call-1',
        ip: '127.0.0.1',
        audioPath: tmp.path,
        codec: 'alaw',
        idleTimeout: const Duration(seconds: 60),
      );
      expect(outcome.port, greaterThan(0));
      expect(outcome.codec, 'alaw');
      expect(outcome.container, 'wav');
      expect(outcome.sampleRate, 8000);
      expect(pool.active(), contains('call-1'));

      final sender = await RawDatagramSocket.bind('127.0.0.1', 0);
      final payload = Uint8List(160)..fillRange(0, 160, 0xD5);
      for (var i = 0; i < 10; i++) {
        final pkt = _rtpPacket(
          sequence: i,
          timestamp: i * 160,
          ssrc: 0xCAFEBABE,
          payload: payload,
        );
        // RawDatagramSocket.send is non-blocking; if the OS UDP buffer
        // is momentarily full it returns 0. Retry until the whole
        // datagram is queued.
        while (
            sender.send(pkt, InternetAddress('127.0.0.1'), outcome.port) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        // Tiny yield so the receive-side isolate gets scheduled between
        // sends; without this the loopback stack drops packets under
        // burst.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Give the worker time to receive + write.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sender.close();

      final result = await pool.stop('call-1');
      expect(result, isNotNull);
      expect(result!.packetCount, 10);
      expect(result.bytesWritten, 10 * 160);
      expect(result.codec, 'alaw');
      expect(result.container, 'wav');
      expect(pool.active(), isEmpty);

      final file = File('${tmp.path}/call-1.wav');
      expect(file.existsSync(), isTrue);
      // 58-byte a-law WAV header + 1600 bytes payload = 1658 bytes.
      expect(file.lengthSync(), 58 + 10 * 160);
    });

    test('distributes concurrent starts across workers (least-loaded)',
        () async {
      await RecorderWorkerPool.initialize(
        mode: WorkerMode.isolated,
        workerCount: 3,
      );
      final pool = RecorderWorkerPool.instance!;

      // Start three sequentially — least-loaded picker should place one
      // on each worker.
      for (var i = 0; i < 3; i++) {
        await pool.start(
          filename: 'call-$i',
          ip: '127.0.0.1',
          audioPath: tmp.path,
          codec: 'pcm',
          idleTimeout: const Duration(seconds: 60),
        );
      }
      expect(pool.workerLoad(), [1, 1, 1]);

      for (var i = 0; i < 3; i++) {
        final r = await pool.stop('call-$i');
        expect(r, isNotNull);
      }
      expect(pool.workerLoad(), [0, 0, 0]);
      expect(pool.active(), isEmpty);
    });

    test('rejects duplicate filenames', () async {
      await RecorderWorkerPool.initialize(
        mode: WorkerMode.isolated,
        workerCount: 1,
      );
      final pool = RecorderWorkerPool.instance!;

      await pool.start(
        filename: 'dup',
        ip: '127.0.0.1',
        audioPath: tmp.path,
        codec: 'pcm',
        idleTimeout: const Duration(seconds: 60),
      );

      await expectLater(
        pool.start(
          filename: 'dup',
          ip: '127.0.0.1',
          audioPath: tmp.path,
          codec: 'pcm',
          idleTimeout: const Duration(seconds: 60),
        ),
        throwsA(isA<DuplicateRecordingException>()),
      );

      await pool.stop('dup');
    });

    test('auto-finalizes on RTP idle and drops from routing table', () async {
      await RecorderWorkerPool.initialize(
        mode: WorkerMode.isolated,
        workerCount: 1,
      );
      final pool = RecorderWorkerPool.instance!;

      // Worker polls the idle deadline every 5 s, and the shortest idle
      // window we can configure is 1 s. So worst-case wait: ~6 s.
      final outcome = await pool.start(
        filename: 'idle-call',
        ip: '127.0.0.1',
        audioPath: tmp.path,
        codec: 'pcm',
        idleTimeout: const Duration(seconds: 1),
      );
      expect(outcome.port, greaterThan(0));
      expect(pool.active(), contains('idle-call'));

      final finalized = await _waitFor(
        () => !pool.isActive('idle-call'),
        timeout: const Duration(seconds: 10),
      );
      expect(finalized, isTrue, reason: 'idle timer should auto-finalize');
      expect(pool.workerLoad(), [0]);
      expect(File('${tmp.path}/idle-call.wav').existsSync(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
