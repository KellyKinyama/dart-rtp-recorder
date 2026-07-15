import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../codecs/g711/dart_g711.dart';
import '../recorder/pcm_wav_sink.dart';
import '../recorder/rtp_server.dart' show audioPath;

// ---------------------------------------------------------------------------
// Playback configuration.
// ---------------------------------------------------------------------------

/// If `true`, the `/playback` endpoint populates a PCM WAV cache in
/// [playbackCachePath] the first time a G.711 recording is requested.
/// Populated from `PLAYBACK_CACHE_ENABLED` in `bin/dart_rtp_recorder.dart`.
bool playbackCacheEnabled = true;

/// Directory where transcoded PCM WAVs are cached (see [playbackCacheEnabled]).
/// Populated from `PLAYBACK_CACHE_PATH` in `bin/dart_rtp_recorder.dart`.
/// Empty string disables caching regardless of [playbackCacheEnabled].
String playbackCachePath = '';

// ---------------------------------------------------------------------------
// WAV header parsing.
// ---------------------------------------------------------------------------

/// Metadata extracted from a WAV file's headers, sufficient to serve or
/// transcode it. Used by [playbackRecording] to decide whether the source
/// is already PCM (sendfile path) or G.711 (transcode path).
class WavInfo {
  WavInfo({
    required this.audioFormat,
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataSize,
  });

  /// `fmt ` chunk `AudioFormat` field. `1` = PCM, `6` = a-law, `7` = mu-law.
  final int audioFormat;
  final int numChannels;
  final int sampleRate;
  final int bitsPerSample;

  /// Absolute file offset (bytes) where the `data` chunk body starts.
  final int dataOffset;

  /// Size (bytes) of the `data` chunk body.
  final int dataSize;

  bool get isPcm => audioFormat == 1;
  bool get isG711 => audioFormat == 6 || audioFormat == 7;
  bool get isAlaw => audioFormat == 6;
  bool get isMulaw => audioFormat == 7;
}

/// Parse the RIFF/WAVE headers of [raf]. Walks the chunk list so it works
/// for both PCM (16-byte `fmt`) and G.711 (18-byte `fmt` + `fact`) files
/// and tolerates any extra unknown chunks that may appear in the future.
///
/// Throws [FormatException] if the file is not a RIFF/WAVE stream or the
/// required chunks are missing.
Future<WavInfo> readWavInfo(RandomAccessFile raf) async {
  await raf.setPosition(0);
  final riff = await raf.read(12);
  if (riff.length < 12 ||
      String.fromCharCodes(riff, 0, 4) != 'RIFF' ||
      String.fromCharCodes(riff, 8, 12) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  int audioFormat = 0;
  int numChannels = 0;
  int sampleRate = 0;
  int bitsPerSample = 0;
  int dataOffset = 0;
  int dataSize = 0;

  while (true) {
    final hdr = await raf.read(8);
    if (hdr.length < 8) break;
    final id = String.fromCharCodes(hdr, 0, 4);
    final size = ByteData.view(
      Uint8List.fromList(hdr).buffer,
    ).getUint32(4, Endian.little);

    if (id == 'fmt ') {
      final body = await raf.read(size);
      if (body.length < 16) {
        throw const FormatException('fmt chunk too small');
      }
      final bd = ByteData.view(Uint8List.fromList(body).buffer);
      audioFormat = bd.getUint16(0, Endian.little);
      numChannels = bd.getUint16(2, Endian.little);
      sampleRate = bd.getUint32(4, Endian.little);
      bitsPerSample = bd.getUint16(14, Endian.little);
      // Skip pad byte on odd sizes.
      if (size.isOdd) {
        await raf.setPosition(await raf.position() + 1);
      }
    } else if (id == 'data') {
      dataOffset = await raf.position();
      dataSize = size;
      break;
    } else {
      // Skip unknown chunk (pad byte on odd sizes).
      final skip = size + (size.isOdd ? 1 : 0);
      await raf.setPosition(await raf.position() + skip);
    }
  }

  if (audioFormat == 0 || dataOffset == 0) {
    throw const FormatException('missing fmt or data chunk');
  }
  return WavInfo(
    audioFormat: audioFormat,
    numChannels: numChannels,
    sampleRate: sampleRate,
    bitsPerSample: bitsPerSample,
    dataOffset: dataOffset,
    dataSize: dataSize,
  );
}

// ---------------------------------------------------------------------------
// HTTP Range parsing.
// ---------------------------------------------------------------------------

/// Parsed byte range. `start` and `end` are inclusive, 0-based. If the
/// requested range is unsatisfiable (client asked past EOF), [satisfiable]
/// is `false` and the caller should respond `416 Requested Range Not
/// Satisfiable`.
class ByteRange {
  ByteRange(this.start, this.end,
      {this.satisfiable = true, this.partial = false});

  final int start;
  final int end;
  final bool satisfiable;
  final bool partial;

  int get length => end - start + 1;
}

/// Parse an HTTP `Range` header of the form `bytes=start-end`,
/// `bytes=start-`, or `bytes=-suffix`. Returns a full-file range if
/// [header] is null or unparseable, and marks the result unsatisfiable
/// if the requested range falls entirely outside the file.
ByteRange parseRange(String? header, int totalLength) {
  if (totalLength <= 0) {
    return ByteRange(0, -1, satisfiable: false);
  }
  if (header == null || header.trim().isEmpty) {
    return ByteRange(0, totalLength - 1);
  }
  final m =
      RegExp(r'^\s*bytes\s*=\s*(\d+)?\s*-\s*(\d+)?\s*$').firstMatch(header);
  if (m == null) return ByteRange(0, totalLength - 1);

  final startStr = m.group(1);
  final endStr = m.group(2);
  int start;
  int end;

  if (startStr == null && endStr != null) {
    // Suffix range: last N bytes.
    final suffix = int.parse(endStr);
    if (suffix <= 0) return ByteRange(0, -1, satisfiable: false);
    start = totalLength - suffix;
    if (start < 0) start = 0;
    end = totalLength - 1;
  } else if (startStr != null) {
    start = int.parse(startStr);
    end = endStr != null ? int.parse(endStr) : totalLength - 1;
  } else {
    return ByteRange(0, totalLength - 1);
  }

  if (start >= totalLength) {
    return ByteRange(0, -1, satisfiable: false);
  }
  if (end > totalLength - 1) end = totalLength - 1;
  if (start > end) return ByteRange(0, -1, satisfiable: false);

  final partial = !(start == 0 && end == totalLength - 1);
  return ByteRange(start, end, partial: partial);
}

// ---------------------------------------------------------------------------
// Streaming G.711 -> PCM WAV transcode.
// ---------------------------------------------------------------------------

/// Stream a byte-range slice of a PCM WAV that would result from decoding
/// [info] (a G.711 source) via [codec]. Emits the synthesized 44-byte PCM
/// header followed by decoded PCM bytes; supports Range requests exactly
/// by trimming leading/trailing bytes of the first/last decoded chunk.
///
/// The stream reads from [srcRaf] positionally — the caller retains
/// ownership and MUST close it after the returned stream completes.
Stream<List<int>> streamTranscodedPcmRange({
  required RandomAccessFile srcRaf,
  required WavInfo info,
  required DartG711Codec codec,
  required int outStart,
  required int outEnd,
}) async* {
  final outHeader = PcmWavSink.buildRiffHeader(
    dataSize: 2 * info.dataSize,
    sampleRate: info.sampleRate,
    numChannels: info.numChannels,
    bytesPerSample: 2,
  );

  // Header slice.
  if (outStart < 44) {
    final headerEnd = outEnd < 43 ? outEnd : 43;
    yield Uint8List.sublistView(outHeader, outStart, headerEnd + 1);
    if (outEnd < 44) return;
  }

  // Body slice. Every source a-law/mu-law byte expands to 2 PCM bytes
  // (one little-endian int16 sample), so the mapping is stateless and
  // trivial.
  final bodyStart = (outStart < 44 ? 44 : outStart) - 44;
  final bodyEnd = outEnd - 44;
  final srcStart = info.dataOffset + bodyStart ~/ 2;
  final srcEnd = info.dataOffset + bodyEnd ~/ 2; // inclusive
  final trimFront = bodyStart & 1; // 0 or 1
  final trimBack = 1 - (bodyEnd & 1); // 0 or 1

  await srcRaf.setPosition(srcStart);
  int remaining = srcEnd - srcStart + 1;
  const chunkSize = 4096;
  bool isFirst = true;
  while (remaining > 0) {
    final want = remaining < chunkSize ? remaining : chunkSize;
    final chunk = await srcRaf.read(want);
    if (chunk.isEmpty) break;
    remaining -= chunk.length;
    final pcm = codec.decode(Uint8List.fromList(chunk));
    final isLast = remaining <= 0;
    int lo = 0;
    int hi = pcm.length;
    if (isFirst && trimFront > 0) lo = trimFront;
    if (isLast && trimBack > 0) hi = pcm.length - trimBack;
    isFirst = false;
    if (hi > lo) yield Uint8List.sublistView(pcm, lo, hi);
  }
}

// ---------------------------------------------------------------------------
// HTTP handler.
// ---------------------------------------------------------------------------

/// `GET /playback?filename=X[&cache=0]` — return the recording as a
/// browser-playable PCM WAV.
///
/// Behavior by source-file audio format:
///   * PCM (Phase 1)  — sendfile with Range support (no CPU).
///   * G.711 (Phase 2) — stream-decode to 16-bit PCM WAV with Range
///     support (Option A). If [playbackCacheEnabled] is true and
///     [playbackCachePath] is set, kick off a background full-file
///     transcode so subsequent requests are served from the cache with
///     sendfile (Option B). Pass `?cache=0` to skip both the cache
///     lookup and the background populate for a specific request.
Future<void> playbackRecording(String filename, HttpRequest request) async {
  final safeName = _sanitizeFilename(filename);
  final srcPath = '$audioPath/$safeName.wav';
  final srcFile = File(srcPath);

  final cacheOptOut = request.uri.queryParameters['cache'] == '0';
  final cacheEnabled =
      playbackCacheEnabled && playbackCachePath.isNotEmpty && !cacheOptOut;

  // ---- Cache hit path (checked BEFORE opening the source) ---------------
  //
  // If a cached PCM WAV exists and is not older than the source (allowing
  // for filesystem mtime granularity), serve it with `sendfile` — no
  // decode, no source read. This is Option B and also means playback
  // continues to work if the raw source has been deleted or archived.
  if (cacheEnabled) {
    final cachedFile = File('$playbackCachePath/$safeName.pcm.wav');
    if (cachedFile.existsSync()) {
      final srcExists = srcFile.existsSync();
      final stale = srcExists &&
          cachedFile.lastModifiedSync().isBefore(
                srcFile.lastModifiedSync().subtract(const Duration(seconds: 1)),
              );
      if (!stale) {
        await _serveFileWithRange(cachedFile, request);
        return;
      }
    }
  }

  // ---- Source is required from here on ---------------------------------
  if (!srcFile.existsSync()) {
    await _writeJsonError(
      request,
      HttpStatus.notFound,
      'no such recording',
      {'filename': safeName},
    );
    return;
  }

  final RandomAccessFile srcRaf;
  final WavInfo info;
  try {
    srcRaf = await srcFile.open();
    info = await readWavInfo(srcRaf);
  } on FormatException catch (e) {
    await _writeJsonError(
      request,
      HttpStatus.unsupportedMediaType,
      'invalid WAV source',
      {'detail': '$e'},
    );
    return;
  }

  // Only PCM/a-law/mu-law are supported today.
  if (!info.isPcm && !info.isG711) {
    await srcRaf.close();
    await _writeJsonError(
      request,
      HttpStatus.unsupportedMediaType,
      'unsupported source codec',
      {'audio_format': info.audioFormat},
    );
    return;
  }

  // PCM source: nothing to transcode; sendfile directly.
  if (info.isPcm) {
    await srcRaf.close();
    await _serveFileWithRange(srcFile, request);
    return;
  }

  // G.711 source: stream-decode Option-A style.
  final codec = info.isAlaw ? DartG711Codec.g711a() : DartG711Codec.g711u();
  final pcmTotal = 44 + 2 * info.dataSize;
  final range = parseRange(request.headers.value('range'), pcmTotal);
  if (!range.satisfiable) {
    request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    request.response.headers
        .set(HttpHeaders.contentRangeHeader, 'bytes */$pcmTotal');
    await srcRaf.close();
    await request.response.close();
    return;
  }
  request.response.statusCode =
      range.partial ? HttpStatus.partialContent : HttpStatus.ok;
  request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
  request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  request.response.headers
      .set(HttpHeaders.contentLengthHeader, '${range.length}');
  if (range.partial) {
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${range.start}-${range.end}/$pcmTotal',
    );
  }
  try {
    await request.response.addStream(streamTranscodedPcmRange(
      srcRaf: srcRaf,
      info: info,
      codec: codec,
      outStart: range.start,
      outEnd: range.end,
    ));
    await request.response.close();
  } finally {
    await srcRaf.close();
  }

  // Option B: populate the on-disk cache in the background so the next
  // playback is served with sendfile.
  if (cacheEnabled) {
    unawaited(_populateCache(safeName: safeName, srcPath: srcPath));
  }
}

/// Serve [file] with `audio/wav` content type and HTTP Range support.
Future<void> _serveFileWithRange(File file, HttpRequest request) async {
  final total = await file.length();
  final range = parseRange(request.headers.value('range'), total);
  if (!range.satisfiable) {
    request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    request.response.headers
        .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
    await request.response.close();
    return;
  }
  request.response.statusCode =
      range.partial ? HttpStatus.partialContent : HttpStatus.ok;
  request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
  request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  request.response.headers
      .set(HttpHeaders.contentLengthHeader, '${range.length}');
  if (range.partial) {
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${range.start}-${range.end}/$total',
    );
  }
  await request.response.addStream(file.openRead(range.start, range.end + 1));
  await request.response.close();
}

/// Kick off a background cache-populate for [safeName] and return
/// immediately. The heavy work (whole-file G.711 → PCM WAV transcode)
/// runs on a fresh isolate via [Isolate.run] so the main event loop
/// stays free to accept RTP and serve concurrent /playback requests.
///
/// Fire-and-forget; errors are logged, not surfaced. Safe against
/// concurrent invocations for the same file (later invocations discard
/// their tmp on rename conflict).
Future<void> _populateCache({
  required String safeName,
  required String srcPath,
}) async {
  // Snapshot the global here — inside the worker isolate, module-level
  // variables are re-initialized to their declared defaults and do NOT
  // reflect values set in the main isolate at startup.
  final cachePath = playbackCachePath;
  try {
    await Isolate.run(
      () => _cachePopulateWorker(safeName, srcPath, cachePath),
      debugName: 'cache-populate:$safeName',
    );
  } catch (e) {
    print('Cache populate failed for $safeName: $e');
  }
}

/// Isolate entry point for [_populateCache]. Reads [srcPath] (expected
/// to be a G.711 WAV), decodes the entire data chunk to 16-bit PCM,
/// writes a canonical PCM WAV to a `.tmp.<micros>` file in [cachePath],
/// then atomic-renames into place at `<cachePath>/<safeName>.pcm.wav`.
///
/// Runs in a fresh isolate — do NOT read main-isolate globals here.
/// Anything the worker needs must be threaded through this signature.
Future<void> _cachePopulateWorker(
  String safeName,
  String srcPath,
  String cachePath,
) async {
  final cacheDir = Directory(cachePath);
  await cacheDir.create(recursive: true);
  final finalPath = '${cacheDir.path}/$safeName.pcm.wav';
  if (File(finalPath).existsSync()) return;
  final tmpPath = '$finalPath.tmp.'
      '${DateTime.now().microsecondsSinceEpoch}';

  final srcFile = File(srcPath);
  final srcRaf = await srcFile.open();
  final WavInfo info;
  try {
    info = await readWavInfo(srcRaf);
  } catch (e) {
    await srcRaf.close();
    print('Cache populate: cannot read $srcPath: $e');
    return;
  }
  if (!info.isG711) {
    await srcRaf.close();
    return;
  }
  final codec = info.isAlaw ? DartG711Codec.g711a() : DartG711Codec.g711u();

  final outRaf = await File(tmpPath).open(mode: FileMode.write);
  try {
    outRaf.writeFromSync(PcmWavSink.buildRiffHeader(
      dataSize: 2 * info.dataSize,
      sampleRate: info.sampleRate,
      numChannels: info.numChannels,
      bytesPerSample: 2,
    ));
    await srcRaf.setPosition(info.dataOffset);
    int remaining = info.dataSize;
    const chunkSize = 8192;
    while (remaining > 0) {
      final want = remaining < chunkSize ? remaining : chunkSize;
      final chunk = await srcRaf.read(want);
      if (chunk.isEmpty) break;
      remaining -= chunk.length;
      outRaf.writeFromSync(codec.decode(Uint8List.fromList(chunk)));
    }
    await outRaf.flush();
  } finally {
    await outRaf.close();
    await srcRaf.close();
  }

  try {
    await File(tmpPath).rename(finalPath);
    print('Playback cache populated: $finalPath');
  } catch (_) {
    // Concurrent request beat us to it; discard tmp.
    try {
      await File(tmpPath).delete();
    } catch (_) {}
  }
}

Future<void> _writeJsonError(
  HttpRequest request,
  int status,
  String error,
  Map<String, Object?> extra,
) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(json.encode({'error': error, ...extra}));
  await request.response.close();
}

String _sanitizeFilename(String name) {
  final invalid = RegExp(r'[^A-Za-z0-9._-]');
  final cleaned = name.replaceAll(invalid, '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'recording';
  }
  return cleaned;
}
