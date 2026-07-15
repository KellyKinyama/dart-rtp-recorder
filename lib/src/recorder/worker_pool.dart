import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../config.dart';
import '../db_queries.dart';
import '../rtp/rtp_packet.dart';
import 'recording_sink.dart';
import 'sink_factory.dart';

/// Execution model for the recorder.
///
/// * [WorkerMode.inline] — recording runs on the main isolate (current
///   pre-pool behaviour). Used by tests and as a safe fallback when
///   `RECORDER_WORKER_COUNT=0`.
/// * [WorkerMode.isolated] — a fixed pool of worker isolates is spawned
///   at startup; `/start` picks the least-loaded worker, sends the call
///   to it, and the worker owns the UDP socket + sink + idle timer for
///   the rest of that call's lifetime.
enum WorkerMode {
  inline,
  isolated,
}

/// Result of a successful pool-mediated `/start`. Mirrors the fields the
/// HTTP handler puts on the wire.
class StartOutcome {
  StartOutcome({
    required this.port,
    required this.codec,
    required this.container,
    required this.sampleRate,
  });

  final int port;
  final String codec;
  final String container;
  final int sampleRate;
}

/// Thrown by [RecorderWorkerPool.start] when a recording for the given
/// filename is already active on some worker.
class DuplicateRecordingException implements Exception {
  DuplicateRecordingException(this.filename);
  final String filename;
  @override
  String toString() => 'DuplicateRecordingException($filename)';
}

class _WorkerHandle {
  _WorkerHandle({
    required this.index,
    required this.commandPort,
    required this.isolate,
  });

  final int index;
  final SendPort commandPort;
  final Isolate isolate;
  int activeCount = 0;
}

/// Fixed pool of worker isolates, each owning a share of the concurrent
/// recordings. Routes `/start` to the least-loaded worker and `/stop`
/// back to whichever worker owns that filename.
///
/// The pool is a process-wide singleton: initialize once at startup via
/// [initialize], read it via [instance]. Use [reset] to tear it down
/// (tests only).
class RecorderWorkerPool {
  RecorderWorkerPool._();

  static RecorderWorkerPool? _instance;
  static RecorderWorkerPool? get instance => _instance;

  WorkerMode _mode = WorkerMode.inline;
  WorkerMode get mode => _mode;

  final List<_WorkerHandle> _workers = [];
  final Map<String, _WorkerHandle> _routing = {};
  ReceivePort? _mainInbound;

  /// Idempotent initialization. A second call with identical parameters
  /// is a no-op; with different parameters it throws [StateError] so we
  /// don't silently leak workers.
  static Future<void> initialize({
    required WorkerMode mode,
    int workerCount = 1,
  }) async {
    final existing = _instance;
    if (existing != null) {
      if (existing._mode == mode && existing._workers.length == workerCount) {
        return;
      }
      throw StateError(
        'RecorderWorkerPool already initialized with different parameters '
        '(mode=${existing._mode}, workers=${existing._workers.length})',
      );
    }
    final pool = RecorderWorkerPool._();
    pool._mode = mode;
    if (mode == WorkerMode.isolated) {
      if (workerCount < 1) {
        throw ArgumentError.value(workerCount, 'workerCount', 'must be >= 1');
      }
      await pool._spawnWorkers(workerCount);
    }
    _instance = pool;
  }

  /// Tear down the pool. Intended for tests; production processes are
  /// expected to run until killed.
  static Future<void> reset() async {
    final existing = _instance;
    _instance = null;
    if (existing != null) await existing._shutdown();
  }

  /// Whether pool-mode dispatch is active. Callers can use this to
  /// decide between the pooled path and the inline (legacy) path.
  bool get isIsolated => _mode == WorkerMode.isolated;

  /// Current per-worker load (index → active recording count). Exposed
  /// for `/status`.
  List<int> workerLoad() => [for (final w in _workers) w.activeCount];

  /// Whether a recording for [filename] is currently owned by any
  /// worker. Used by the HTTP handler for duplicate detection.
  bool isActive(String filename) => _routing.containsKey(filename);

  /// Snapshot of active recording filenames across all workers.
  List<String> active() => List.unmodifiable(_routing.keys);

  Future<void> _spawnWorkers(int count) async {
    _mainInbound = ReceivePort();
    _mainInbound!.listen(_onMainMessage);
    for (var i = 0; i < count; i++) {
      final ready = ReceivePort();
      final iso = await Isolate.spawn(
        _workerEntry,
        _WorkerBootstrap(
          mainInbound: _mainInbound!.sendPort,
          ready: ready.sendPort,
          index: i,
        ),
        debugName: 'recorder-worker-$i',
      );
      final commandPort = await ready.first as SendPort;
      ready.close();
      _workers.add(_WorkerHandle(
        index: i,
        commandPort: commandPort,
        isolate: iso,
      ));
    }
    print('RecorderWorkerPool: spawned $count worker isolate(s)');
  }

  void _onMainMessage(Object? msg) {
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'autoFinalized':
        final filename = msg['filename'] as String;
        final worker = _routing.remove(filename);
        if (worker != null) {
          worker.activeCount =
              (worker.activeCount - 1).clamp(0, 1 << 30);
        }
        final db = msg['db'];
        if (db is Map) _mainDbInsert(db.cast<String, dynamic>());
        break;
      case 'dbInsert':
        _mainDbInsert(msg.cast<String, dynamic>());
        break;
    }
  }

  Future<void> _mainDbInsert(Map<String, dynamic> m) async {
    // Skip when the DB isn't configured (tests, pool-only smoke runs).
    // `Config` uses `late String`, so an uninitialized field throws
    // `LateInitializationError` on read — treat that as "no DB".
    bool configured;
    try {
      configured = Config.asteriskDbHost.isNotEmpty;
    } catch (_) {
      configured = false;
    }
    if (!configured) return;
    try {
      await DbQueries.insertRecording(
        filename: m['filename'] as String,
        codec: m['codec'] as String,
        container: m['container'] as String,
        sampleRate: m['sampleRate'] as int,
        durationMs: m['durationMs'] as int,
        bytes: m['bytes'] as int,
      );
    } catch (e) {
      print('Pool DB insert failed for ${m['filename']}: $e');
    }
  }

  _WorkerHandle _pickWorker() {
    var best = _workers.first;
    for (final w in _workers) {
      if (w.activeCount < best.activeCount) best = w;
    }
    return best;
  }

  /// Route a new recording to the least-loaded worker. Throws
  /// [DuplicateRecordingException] if [filename] is already active.
  Future<StartOutcome> start({
    required String filename,
    required String ip,
    required String audioPath,
    required String codec,
    required Duration idleTimeout,
  }) async {
    if (_routing.containsKey(filename)) {
      throw DuplicateRecordingException(filename);
    }
    final worker = _pickWorker();
    final reply = ReceivePort();
    worker.commandPort.send({
      'type': 'start',
      'filename': filename,
      'ip': ip,
      'audioPath': audioPath,
      'codec': codec,
      'idleTimeoutSeconds': idleTimeout.inSeconds,
      'reply': reply.sendPort,
    });
    final Map resp;
    try {
      resp = (await reply.first) as Map;
    } finally {
      reply.close();
    }
    if (resp['ok'] != true) {
      throw StateError(resp['error']?.toString() ?? 'start failed');
    }
    _routing[filename] = worker;
    worker.activeCount++;
    return StartOutcome(
      port: resp['port'] as int,
      codec: resp['codec'] as String,
      container: resp['container'] as String,
      sampleRate: resp['sampleRate'] as int,
    );
  }

  /// Finalize a recording. Returns `null` if no worker owns [filename].
  Future<RecordingResult?> stop(String filename) async {
    final worker = _routing.remove(filename);
    if (worker == null) return null;
    worker.activeCount = (worker.activeCount - 1).clamp(0, 1 << 30);
    final reply = ReceivePort();
    worker.commandPort.send({
      'type': 'stop',
      'filename': filename,
      'reply': reply.sendPort,
    });
    final Map resp;
    try {
      resp = (await reply.first) as Map;
    } finally {
      reply.close();
    }
    if (resp['ok'] != true) {
      throw StateError(resp['error']?.toString() ?? 'stop failed');
    }
    final r = (resp['result'] as Map).cast<String, dynamic>();
    return RecordingResult(
      filename: r['filename'] as String,
      path: r['path'] as String,
      codec: r['codec'] as String,
      container: r['container'] as String,
      sampleRate: r['sample_rate'] as int,
      packetCount: r['packet_count'] as int,
      bytesWritten: r['bytes'] as int,
      duration: Duration(milliseconds: r['duration_ms'] as int),
    );
  }

  Future<void> _shutdown() async {
    for (final w in _workers) {
      final reply = ReceivePort();
      try {
        w.commandPort.send({'type': 'shutdown', 'reply': reply.sendPort});
        await reply.first.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Best-effort; force-kill below.
      } finally {
        reply.close();
      }
      w.isolate.kill(priority: Isolate.immediate);
    }
    _workers.clear();
    _routing.clear();
    _mainInbound?.close();
    _mainInbound = null;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate side. Everything below runs in the spawned isolate; do NOT
// reference `RecorderWorkerPool` state from here.
// ---------------------------------------------------------------------------

class _WorkerBootstrap {
  _WorkerBootstrap({
    required this.mainInbound,
    required this.ready,
    required this.index,
  });

  final SendPort mainInbound;
  final SendPort ready;
  final int index;
}

class _WorkerRecording {
  _WorkerRecording({
    required this.socket,
    required this.sink,
    required this.filename,
  });

  final RawDatagramSocket socket;
  final RecordingSink sink;
  final String filename;
  DateTime lastPacketAt = DateTime.now();
  Timer? idleTimer;
  Completer<Map<String, dynamic>>? finalizing;
}

Future<void> _workerEntry(_WorkerBootstrap boot) async {
  final commandPort = ReceivePort();
  boot.ready.send(commandPort.sendPort);
  final mainInbound = boot.mainInbound;
  final active = <String, _WorkerRecording>{};

  await for (final msg in commandPort) {
    if (msg is! Map) continue;
    switch (msg['type']) {
      case 'start':
        // Fire-and-forget the async handler so subsequent messages
        // aren't blocked behind a slow socket bind.
        unawaited(_handleStart(
            msg.cast<String, dynamic>(), active, mainInbound));
        break;
      case 'stop':
        unawaited(_handleStop(
            msg.cast<String, dynamic>(), active, mainInbound));
        break;
      case 'shutdown':
        final reply = msg['reply'] as SendPort?;
        for (final rec in active.values.toList()) {
          try {
            await _workerFinalize(rec, active, mainInbound,
                autoFinalized: false);
          } catch (_) {}
        }
        reply?.send({'ok': true});
        commandPort.close();
        return;
    }
  }
}

Future<void> _handleStart(
  Map<String, dynamic> msg,
  Map<String, _WorkerRecording> active,
  SendPort mainInbound,
) async {
  final reply = msg['reply'] as SendPort;
  final filename = msg['filename'] as String;
  final ip = msg['ip'] as String;
  final audioPath = msg['audioPath'] as String;
  final codec = msg['codec'] as String;
  final idleSecs = msg['idleTimeoutSeconds'] as int;

  final RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress(ip), 0);
  } catch (e) {
    reply.send({'ok': false, 'error': 'UDP bind failed: $e'});
    return;
  }

  final RecordingSink sink;
  try {
    sink = createRecordingSink('$audioPath/$filename.wav', codec: codec);
    await sink.open();
  } catch (e) {
    try {
      socket.close();
    } catch (_) {}
    reply.send({'ok': false, 'error': 'sink open failed: $e'});
    return;
  }

  final rec = _WorkerRecording(socket: socket, sink: sink, filename: filename);
  active[filename] = rec;

  socket.listen(
    (event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      try {
        final packet = RTPpacket.fromList(d.data, d.data.lengthInBytes);
        rec.sink.write(packet.payload, packet.PayloadType);
        rec.lastPacketAt = DateTime.now();
      } catch (e) {
        print('Bad RTP packet for $filename: $e');
      }
    },
    onError: (Object e) {
      print('UDP socket error on $filename: $e');
    },
  );

  final idleTimeout = Duration(seconds: idleSecs);
  rec.idleTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
    if (DateTime.now().difference(rec.lastPacketAt) < idleTimeout) return;
    print('Recording $filename idle for ${idleSecs}s; finalizing');
    t.cancel();
    try {
      await _workerFinalize(rec, active, mainInbound, autoFinalized: true);
    } catch (e) {
      print('Auto-finalize error for $filename: $e');
    }
  });

  reply.send({
    'ok': true,
    'port': socket.port,
    'codec': sink.codec,
    'container': sink.container,
    'sampleRate': sink.sampleRate,
  });
}

Future<void> _handleStop(
  Map<String, dynamic> msg,
  Map<String, _WorkerRecording> active,
  SendPort mainInbound,
) async {
  final reply = msg['reply'] as SendPort;
  final filename = msg['filename'] as String;
  final rec = active[filename];
  if (rec == null) {
    reply.send({'ok': false, 'error': 'no active recording'});
    return;
  }
  try {
    final result = await _workerFinalize(rec, active, mainInbound,
        autoFinalized: false);
    reply.send({'ok': true, 'result': result});
  } catch (e) {
    reply.send({'ok': false, 'error': '$e'});
  }
}

Future<Map<String, dynamic>> _workerFinalize(
  _WorkerRecording rec,
  Map<String, _WorkerRecording> active,
  SendPort mainInbound, {
  required bool autoFinalized,
}) async {
  final existing = rec.finalizing;
  if (existing != null) return existing.future;
  final c = Completer<Map<String, dynamic>>();
  rec.finalizing = c;
  try {
    rec.idleTimer?.cancel();
    try {
      rec.socket.close();
    } catch (_) {}
    await rec.sink.close();
    active.remove(rec.filename);

    final result = RecordingResult(
      filename: rec.filename,
      path: rec.sink.path,
      codec: rec.sink.codec,
      container: rec.sink.container,
      sampleRate: rec.sink.sampleRate,
      packetCount: rec.sink.packetCount,
      bytesWritten: rec.sink.bytesWritten,
      duration: rec.sink.duration,
    );
    final resultJson = result.toJson();

    final db = <String, dynamic>{
      'filename': rec.filename,
      'codec': rec.sink.codec,
      'container': rec.sink.container,
      'sampleRate': rec.sink.sampleRate,
      'durationMs': rec.sink.duration.inMilliseconds,
      'bytes': rec.sink.bytesWritten,
    };
    if (autoFinalized) {
      // Ask main to drop routing AND persist to DB in one message.
      mainInbound.send({
        'type': 'autoFinalized',
        'filename': rec.filename,
        'db': db,
      });
    } else {
      // Main already dropped routing when it received `/stop`; just
      // ask it to persist.
      final insertMsg = <String, dynamic>{'type': 'dbInsert'}..addAll(db);
      mainInbound.send(insertMsg);
    }

    c.complete(resultJson);
    return resultJson;
  } catch (e, st) {
    c.completeError(e, st);
    rethrow;
  }
}
