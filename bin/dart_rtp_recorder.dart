import 'dart:io';

import 'package:dart_rtp_recorder/dart_rtp_recorder.dart';
import 'package:dart_rtp_recorder/src/config.dart';
import 'package:dart_rtp_recorder/src/http/playback.dart';
import 'package:dart_rtp_recorder/src/recorder/worker_pool.dart';

import 'package:dotenv/dotenv.dart';

Future<void> main(List<String> arguments) async {
  var env = DotEnv(includePlatformEnvironment: true)..load();
  String ip = env['HTTP_SERVER_ADDRESS']!;
  int port = int.parse(env['HTTP_SERVER_PORT']!);
  audioPath = env['AUDIO_PATH']!;

  // Fail-fast: make sure AUDIO_PATH exists AND we can actually write to
  // it. Otherwise the first `/start` call would fail with a cryptic 500
  // deep inside sink.open(), long after the operator has moved on.
  try {
    final dir = Directory(audioPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final probe = File(
        '$audioPath/.write-probe-${DateTime.now().microsecondsSinceEpoch}');
    probe.writeAsBytesSync(const <int>[0]);
    probe.deleteSync();
  } catch (e) {
    stderr.writeln('FATAL: AUDIO_PATH="$audioPath" is not writable: $e');
    exit(78); // EX_CONFIG (sysexits.h)
  }

  // Recorder settings (Phase 0).
  recorderCodec = (env['RECORDER_CODEC'] ?? 'pcm').trim().toLowerCase();
  final idleSecs = int.tryParse(env['RECORDER_IDLE_TIMEOUT_SECONDS'] ?? '');
  if (idleSecs != null && idleSecs > 0) {
    recorderIdleTimeout = Duration(seconds: idleSecs);
  }

  // Playback cache (Option A + Option B).
  final cacheFlag =
      (env['PLAYBACK_CACHE_ENABLED'] ?? 'true').trim().toLowerCase();
  playbackCacheEnabled =
      cacheFlag == 'true' || cacheFlag == '1' || cacheFlag == 'yes';
  playbackCachePath =
      (env['PLAYBACK_CACHE_PATH'] ?? '$audioPath/.pcm-cache').trim();

  //initialise recorde daatabase values
  Config.asteriskDbHost = env['AST_DB_HOST']!;
  Config.asteriskDbPort = env['AST_DB_PORT']!;
  Config.asteriskDbName = env['AST_DB_DATABASE']!;
  Config.asteriskDbUsername = env['AST_DB_USERNAME']!;
  Config.asteriskDbPassword = env['AST_DB_PASSWORD']!;

  // Worker-isolate pool. Defaults to `Platform.numberOfProcessors - 1`
  // (clamped to [1..16]); set `RECORDER_WORKER_COUNT=0` to force the
  // legacy inline path (recording runs on the main isolate).
  final requestedWorkers = int.tryParse(env['RECORDER_WORKER_COUNT'] ?? '');
  final defaultWorkers = (Platform.numberOfProcessors - 1).clamp(1, 16).toInt();
  final workerCount = requestedWorkers ?? defaultWorkers;
  if (workerCount > 0) {
    await RecorderWorkerPool.initialize(
      mode: WorkerMode.isolated,
      workerCount: workerCount,
    );
  } else {
    await RecorderWorkerPool.initialize(mode: WorkerMode.inline);
  }

  HttpRtpServer(ip, port);
  print('listening on $ip:$port '
      '(codec=$recorderCodec, '
      'idle_timeout=${recorderIdleTimeout.inSeconds}s, '
      'audio_path=$audioPath, '
      'workers=$workerCount, '
      'playback_cache=${playbackCacheEnabled ? playbackCachePath : "disabled"})');
}
