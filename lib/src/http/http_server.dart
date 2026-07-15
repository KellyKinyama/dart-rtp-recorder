import 'dart:convert';
import 'dart:io';

import '../recorder/rtp_server.dart';
import 'playback.dart';

/// HTTP control API for the RTP recorder.
///
/// Endpoints (`filename` is required on all of them except `/status`;
/// caller-supplied names are sanitized server-side):
///
///   * `GET|POST /`         — alias for `/start` (backward compat).
///   * `GET|POST /start?filename=X`
///       Bind an ephemeral UDP port, start recording; returns
///       `{"file_name":..., "rtp_port":..., "codec":..., ...}`.
///   * `GET|POST /stop?filename=X`
///       Finalize the recording (patch WAV header, flush, close, persist
///       DB row); returns the full [RecordingResult] as JSON.
///   * `GET     /playback?filename=X[&cache=0]`
///       Serve the recording as a browser-playable PCM WAV. G.711 sources
///       are transcoded on the fly (Option A) and asynchronously cached
///       to disk (Option B); PCM sources are served directly. Supports
///       HTTP Range so `<audio controls>` scrubbing works.
///   * `GET     /status`
///       Returns the list of currently active recording filenames.
class HttpRtpServer {
  HttpRtpServer(String ip, int port) {
    HttpServer.bind(InternetAddress(ip), port).then((HttpServer server) {
      server.listen((HttpRequest request) async {
        try {
          await _dispatch(ip, request);
        } catch (e, st) {
          print('HTTP handler error: $e\n$st');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.headers.contentType = ContentType.json;
            request.response.write(json.encode({
              'error': 'internal error',
              'detail': '$e',
            }));
            await request.response.close();
          } catch (_) {
            // Response may already be closed; ignore.
          }
        }
      });
    });
  }

  Future<void> _dispatch(String ip, HttpRequest request) async {
    final path = request.uri.path.toLowerCase();

    if (path == '/status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'active': RecordingRegistry.active(),
      }));
      await request.response.close();
      return;
    }

    final filename = request.uri.queryParameters['filename'];
    if (filename == null || filename.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'error': 'missing required query parameter "filename"',
      }));
      await request.response.close();
      return;
    }

    switch (path) {
      case '/':
      case '/start':
        await startRecording(ip, filename, request);
        break;
      case '/stop':
        await stopRecording(filename, request);
        break;
      case '/playback':
        await playbackRecording(filename, request);
        break;
      default:
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode({
          'error': 'unknown path',
          'path': path,
        }));
        await request.response.close();
    }
  }
}
