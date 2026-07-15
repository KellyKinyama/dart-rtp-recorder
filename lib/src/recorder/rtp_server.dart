import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_rtp_recorder/src/db_queries.dart';

import '../rtp/rtp_packet.dart';
import 'recording_sink.dart';
import 'sink_factory.dart';

/// Directory where recordings are written. Populated from `AUDIO_PATH` in
/// `bin/dart_rtp_recorder.dart`.
String audioPath = '';

/// Codec/container the recorder writes. Populated from `RECORDER_CODEC` in
/// `bin/dart_rtp_recorder.dart`. Default `pcm` matches Phase 1.
String recorderCodec = 'pcm';

/// How long a recording may go without receiving any RTP before being
/// auto-finalized. Populated from `RECORDER_IDLE_TIMEOUT_SECONDS` in
/// `bin/dart_rtp_recorder.dart`.
Duration recorderIdleTimeout = const Duration(seconds: 60);

/// In-process registry of active recordings, keyed by sanitized filename.
/// Consulted by the `/stop` HTTP endpoint to look up a live recording so it
/// can be finalized deterministically.
class RecordingRegistry {
  static final Map<String, _ActiveRecording> _active = {};

  static void _register(String filename, _ActiveRecording rec) {
    _active[filename] = rec;
  }

  static _ActiveRecording? _remove(String filename) => _active.remove(filename);

  /// Snapshot of currently active recording filenames — useful for /status
  /// endpoints, tests, and shutdown draining.
  static List<String> active() => List.unmodifiable(_active.keys);
}

class _ActiveRecording {
  _ActiveRecording({
    required this.socket,
    required this.sink,
    required this.filename,
  }) : lastPacketAt = DateTime.now();

  final RawDatagramSocket socket;
  final RecordingSink sink;
  final String filename;

  DateTime lastPacketAt;
  Timer? idleTimer;
  Completer<RecordingResult>? _finalizing;

  Future<RecordingResult> finalize() {
    final existing = _finalizing;
    if (existing != null) return existing.future;
    final completer = Completer<RecordingResult>();
    _finalizing = completer;
    () async {
      try {
        idleTimer?.cancel();
        try {
          socket.close();
        } catch (_) {}
        await sink.close();
        final result = RecordingResult(
          filename: filename,
          path: sink.path,
          codec: sink.codec,
          container: sink.container,
          sampleRate: sink.sampleRate,
          packetCount: sink.packetCount,
          bytesWritten: sink.bytesWritten,
          duration: sink.duration,
        );
        try {
          await DbQueries.insertRecording(
            filename: filename,
            codec: result.codec,
            container: result.container,
            sampleRate: result.sampleRate,
            durationMs: result.duration.inMilliseconds,
            bytes: result.bytesWritten,
          );
        } catch (e) {
          print('DB insert failed for $filename: $e');
        }
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }
}

/// Sanitize a caller-supplied filename to prevent path traversal and
/// filesystem-hostile characters. Only alphanumerics plus `.`, `_`, `-`
/// are kept; everything else becomes `_`.
String _sanitizeFilename(String name) {
  final invalid = RegExp(r'[^A-Za-z0-9._-]');
  final cleaned = name.replaceAll(invalid, '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'recording';
  }
  return cleaned;
}

/// Start a new RTP recording. Binds an ephemeral UDP port on [ip], creates
/// the on-disk sink, registers the recording, and replies to [request] with
/// a JSON body containing the sanitized filename and the UDP port to send
/// RTP to.
Future<void> startRecording(
  String ip,
  String filename,
  HttpRequest request,
) async {
  final safeName = _sanitizeFilename(filename);

  // Reject duplicate active recordings for the same filename — otherwise
  // two UDP sockets would race to write the same file.
  if (RecordingRegistry._active.containsKey(safeName)) {
    request.response.statusCode = HttpStatus.conflict;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'error': 'recording already in progress',
      'filename': safeName,
    }));
    await request.response.close();
    return;
  }

  final RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress(ip), 0);
  } catch (e) {
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'error': 'UDP bind failed',
      'detail': '$e',
    }));
    await request.response.close();
    return;
  }

  final RecordingSink sink;
  try {
    sink = createRecordingSink(
      '$audioPath/$safeName.wav',
      codec: recorderCodec,
    );
    await sink.open();
  } catch (e) {
    try {
      socket.close();
    } catch (_) {}
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'error': 'sink open failed',
      'detail': '$e',
    }));
    await request.response.close();
    return;
  }

  final active = _ActiveRecording(
    socket: socket,
    sink: sink,
    filename: safeName,
  );
  RecordingRegistry._register(safeName, active);

  print('Recording $safeName started on '
      '${socket.address.address}:${socket.port} (codec=${sink.codec})');

  request.response.headers.contentType = ContentType.json;
  request.response.write(json.encode({
    'file_name': safeName,
    'rtp_port': socket.port,
    'codec': sink.codec,
    'container': sink.container,
    'sample_rate': sink.sampleRate,
  }));
  await request.response.close();

  socket.listen(
    (RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final Datagram? d = socket.receive();
      if (d == null) return;
      try {
        final packet = RTPpacket.fromList(d.data, d.data.lengthInBytes);
        active.sink.write(packet.payload, packet.PayloadType);
        active.lastPacketAt = DateTime.now();
      } catch (e) {
        print('Bad RTP packet for $safeName: $e');
      }
    },
    onError: (Object e) {
      print('UDP socket error on $safeName: $e');
    },
  );

  // Safety net: if the caller never invokes /stop, finalize after
  // `recorderIdleTimeout` seconds of RTP silence.
  active.idleTimer = Timer.periodic(const Duration(seconds: 5), (t) {
    if (DateTime.now().difference(active.lastPacketAt) >= recorderIdleTimeout) {
      print('Recording $safeName idle for '
          '${recorderIdleTimeout.inSeconds}s; finalizing');
      t.cancel();
      if (RecordingRegistry._remove(safeName) != null) {
        // Log-and-swallow: nothing upstream is awaiting this future, so
        // re-throwing here would just surface as an unhandled async error.
        active.finalize().catchError((Object e) {
          print('Finalize error for $safeName: $e');
          // Return a synthetic result so the Future completes normally.
          return RecordingResult(
            filename: safeName,
            path: active.sink.path,
            codec: active.sink.codec,
            container: active.sink.container,
            sampleRate: active.sink.sampleRate,
            packetCount: active.sink.packetCount,
            bytesWritten: active.sink.bytesWritten,
            duration: active.sink.duration,
          );
        });
      }
    }
  });
}

/// Finalize an in-flight recording. Looks it up in the registry, closes the
/// UDP socket + sink, patches the WAV header, persists metadata to the DB,
/// and returns the [RecordingResult] as JSON.
Future<void> stopRecording(String filename, HttpRequest request) async {
  final safeName = _sanitizeFilename(filename);
  final active = RecordingRegistry._remove(safeName);
  if (active == null) {
    request.response.statusCode = HttpStatus.notFound;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'error': 'no active recording',
      'filename': safeName,
    }));
    await request.response.close();
    return;
  }
  try {
    final result = await active.finalize();
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode(result.toJson()));
    await request.response.close();
  } catch (e) {
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'error': 'finalize failed',
      'detail': '$e',
    }));
    await request.response.close();
  }
}

/// Backwards-compatible alias for the pre-Phase-0 API used by
/// `HttpRtpServer`. New code should call [startRecording] directly.
void rtp_server(String ip, String filename, HttpRequest request) {
  startRecording(ip, filename, request);
}
