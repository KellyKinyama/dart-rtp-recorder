# Recorder Integration Guide

Reference for callers of the `dart-rtp-recorder` HTTP API — primarily
consumed by [dart-ari](../../dart-ari/bin/queue_app_main.dart).

Version: reflects commit `f7f8686` (streaming sinks, playback endpoint,
RTP-parser hardening).

---

## 1. Deployment

The recorder listens on the HTTP address configured by `.env`:

| Env var                          | Purpose                                     | Recommended |
|----------------------------------|---------------------------------------------|-------------|
| `HTTP_SERVER_ADDRESS`            | Bind address for control API + RTP receive | `10.1.101.155` |
| `HTTP_SERVER_PORT`               | Control API port                            | `8090` |
| `AUDIO_PATH`                     | Where `.wav` files are written              | `E:/recordings` |
| `RECORDER_CODEC`                 | `pcm` (Phase 1) or `alaw` / `mulaw` (Phase 2) | **`alaw`** |
| `RECORDER_IDLE_TIMEOUT_SECONDS`  | Auto-finalize after N seconds of RTP silence | `60` |
| `PLAYBACK_CACHE_ENABLED`         | Cache PCM transcodes for browser playback   | `true` |
| `PLAYBACK_CACHE_PATH`            | Directory for transcoded PCM cache          | `${AUDIO_PATH}/.pcm-cache` |
| `AST_DB_*`                       | Asterisk DB for metadata persistence        | (see .env.example) |

On boot the process **fails fast** with `exit(78)` if `AUDIO_PATH` is
missing or read-only — no more silent 500s on the first `/start`.

### Codec sizing (10-min avg call, 6,300 calls/day)

| `RECORDER_CODEC` | Per-call | Per-day | Per-year | Notes |
|------------------|---------:|--------:|---------:|-------|
| `pcm`  (s16le WAV) | 9.60 MB | 60.5 GB | 22.1 TB | Universal playback, biggest disk |
| `alaw` (G.711 WAV) | 4.80 MB | 30.2 GB | 11.0 TB | **Recommended today** — matches ARI's `format: 'alaw'` |
| `mulaw`(G.711 WAV) | 4.80 MB | 30.2 GB | 11.0 TB | For µ-law ITSPs |

Phase 3 (Opus) will bring this to ~2.8 TB/yr. On hold.

---

## 2. HTTP API

All endpoints require a `filename` query parameter (except `/status`).
The name is sanitized server-side: only `[A-Za-z0-9._-]` is kept, everything
else becomes `_`. Empty / `.` / `..` becomes `recording`.

### 2.1 `POST /start`  (aliased by `POST /`)

Reserve a UDP port and open the WAV sink.

**Request**

```http
POST /start?filename=<name> HTTP/1.1
```

**Success `200 OK`**

```json
{
  "file_name": "sanitized-name",
  "rtp_port": 51234,
  "codec": "alaw",
  "container": "wav",
  "sample_rate": 8000
}
```

**Error `409 Conflict`** — a recording with the same filename is already
in flight. The caller must NOT proceed; retry with a new name.

```json
{ "error": "recording already in progress", "filename": "..." }
```

**Error `500`** — UDP bind or sink open failed. Body includes `detail`.

The caller then hands `rtp_port` to Asterisk `externalMedia` with
`format: 'alaw'` (or `pcma`) — matching the recorder's `RECORDER_CODEC`.

### 2.2 `POST /stop`

Finalize the recording deterministically: cancel the idle timer, close the
UDP socket, patch the RIFF header, insert the DB row, return the result.

**Request**

```http
POST /stop?filename=<name> HTTP/1.1
```

**Success `200 OK`**

```json
{
  "filename": "20260714-abc123",
  "path": "E:/recordings/20260714-abc123.wav",
  "codec": "alaw",
  "container": "wav",
  "sample_rate": 8000,
  "packet_count": 45000,
  "bytes_written": 7200000,
  "duration_ms": 900000
}
```

**Error `404`** — no active recording with that name (already stopped, or
never started). Non-fatal for the caller.

> **Integration recommendation (see §3)**: call `/stop` on `StasisEnd`
> of the external-media channel. The ARI client currently relies on the
> 60-second idle timer alone — this works but delays DB row insertion
> and holds the UDP port longer than necessary.

### 2.3 `GET /playback`

Stream the recording back as a browser-playable PCM WAV. G.711 sources
are transcoded on the fly and asynchronously cached to disk so subsequent
requests are `sendfile`-fast.

**Request**

```http
GET /playback?filename=<name>[&cache=0] HTTP/1.1
Range: bytes=0-           (optional; supports arbitrary byte ranges)
```

`&cache=0` — force a fresh on-the-fly transcode; skip and don't populate
the cache. Handy for debug.

**Responses**

- `200 OK` — full body, `Content-Type: audio/wav`, `Accept-Ranges: bytes`.
- `206 Partial Content` — with `Content-Range`, for scrubbing.
- `404 Not Found` — no such recording (source AND cache both absent).
- `415 Unsupported Media Type` — recording is neither PCM nor G.711.
- `416 Range Not Satisfiable` — `Range` header outside file bounds.

**Cache semantics**

1. Cache is checked BEFORE opening the source. A cache hit serves the
   PCM WAV even if the raw source has been archived/deleted.
2. Cache is treated as fresh unless the source is newer than the cache
   by more than 1 second (filesystem mtime tolerance).
3. On cache miss the response is streamed synchronously (Option A) and
   the full PCM WAV is written to disk in the background (Option B).
   The next request gets the fast path.

**Browser usage**

```html
<audio controls src="http://10.1.101.155:8090/playback?filename=call-123"></audio>
```

Chrome / Firefox / Safari all handle Range and PCM WAV out of the box.

### 2.4 `GET /status`

Snapshot of currently active recording filenames. Useful for /health and
graceful-shutdown draining.

```json
{ "active": ["call-abc", "call-def"] }
```

### 2.5 Error envelope

All errors have the same shape:

```json
{ "error": "<short reason>", "detail": "<optional stack/context>" }
```

---

## 3. Integration recommendations for dart-ari

Cross-referenced against
[queue_app_main.dart](../../dart-ari/bin/queue_app_main.dart)
as of this doc's write date. Current integration works but leaves value
on the table.

### 3.1 Call `/stop` on `dialed.StasisEnd`

Today the ARI client calls only `POST /?filename=X` (aliased to `/start`)
and lets the recorder's `recorderIdleTimeout` (default 60 s) finalize
after RTP goes silent. This works but:

- The DB row `recordings` insertion is delayed 60 s after the call ends.
- The UDP port stays bound for those 60 s (no practical limit, but noisy).
- Callers of `CallRecording.insertCallRecording()` currently persist the
  ARI-side metadata; they can't know the true `duration_ms` / `bytes` /
  `codec` the recorder produced, so any billing / storage reporting has
  to re-stat the file separately.

**Suggested change** in `queue_app_main.dart` `originate()`:

```dart
// After externalMedia is created and added to the mixing bridge:
dialed.on('StasisEnd', (_) async {
  await externalChannel!.hangup().catchError((e) => null);
  // NEW — deterministic finalize:
  unawaited(_stopRecorder(filename));
});
```

Helper:

```dart
Future<Map<String, dynamic>?> _stopRecorder(String filename) async {
  final uri = Uri(
    scheme: 'http', host: voiceLoggerIp, port: voiceLoggerPort,
    path: '/stop', queryParameters: {'filename': filename},
  );
  try {
    final req = await httpRtpClient.postUrl(uri);
    final resp = await req.close();
    if (resp.statusCode == 404) return null; // already gone; fine.
    final body = await resp.transform(utf8.decoder).join();
    return json.decode(body) as Map<String, dynamic>;
  } catch (e) {
    print('recorder /stop error for $filename: $e');
    return null;
  }
}
```

Then feed the returned `duration_ms` / `bytes_written` into the
`CallRecording` row alongside `hangupdate`.

### 3.2 Match `RECORDER_CODEC` to `externalMedia(format: ...)`

Today `externalMedia(format: 'alaw', ...)` produces RTP PT=8 (PCMA). If
the recorder is set to `RECORDER_CODEC=pcm` (Phase 1 default), every
packet is decoded to 16-bit PCM — 2× the disk footprint for no playback
benefit (the `/playback` endpoint transcodes on demand anyway).

**Set `RECORDER_CODEC=alaw` in `.env`.** Half the storage, no code
changes on either side. Files remain browser-playable via `/playback`.

### 3.3 New endpoints available (no client change required)

- `/status` — can drive a `/health` probe or a graceful-shutdown
  drainer that waits for `RecordingRegistry.active()` to empty.
- `/playback` — replaces any custom "download and transcode" code the
  QA / supervisor UIs may have. Point an `<audio controls>` element at
  it and playback is Range-scrubbable out of the box.

### 3.4 Handle the new `409 Conflict` (already correct)

`rtpPort()` returns null on a non-200 response, and the recording setup
block already treats null as "skip recording, call continues". No change
needed — just documenting the contract.

### 3.5 RTP parser is now RFC-3550-correct

Previously the parser ignored the P, X and CC header bits. Any softphone
that emits the RFC 6464 client-to-mixer audio-level extension (which
every modern SIP endpoint does) would corrupt the audio with header
bytes rendered as clicks. Fixed as of `f7f8686`.

If you notice a residual buzz / click on recordings from a specific
handset model, capture the RTP with `tcpdump -w file.pcap 'udp and port
<rtp_port>'` and share the first 5 seconds — I'll validate the parse.

---

## 4. Behaviour under load

- **Per-call memory**: <10 KiB (file handle + one transient 160-byte
  buffer per packet). At 30 concurrent calls that's <300 KiB — 4-hour
  and 30-second calls cost the same.
- **Per-call disk I/O**: 50 writes/sec (one per RTP packet); NTFS
  coalesces to a 4 KiB write every ~500 ms. At 30 concurrent calls
  ≈ 240 KB/s of physical write. Trivial for any modern disk.
- **CPU**: <2 % of one core for 30 concurrent PCM recordings. G.711
  passthrough is even less (no decode).
- **RTP receive path is single-threaded** on the Dart event loop.
  Sink writes are `writeFromSync` — synchronous but each call takes
  ~microseconds because it hits the OS write cache, not disk.
- **Playback cache populate runs on a background isolate** (see §5),
  so a `/playback` burst does not stall live RTP recording.

### Failure modes

| Failure | Behaviour |
|---|---|
| Process crash mid-call | On-disk `.wav` contains all bytes written pre-crash. RIFF header still says `dataSize=0`. Recover with a small "fix WAV header from actual data-chunk size" tool (~20 lines) — not shipped yet; open an issue if you hit this and I'll write it. |
| UDP packet loss | Silent gap in audio — no re-request, no compensation. Same as any RTP recorder. |
| Bad RTP packet (short, wrong version, invalid padding) | Logged as `Bad RTP packet for <name>: <FormatException>`, packet skipped, recording continues. |
| DB insert failure at close | Logged as `DB insert failed for <name>: <error>`; the WAV file is still complete on disk. |
| AUDIO_PATH becomes unwritable mid-run | Sink writes throw and the packet is dropped; the recording will produce a truncated file at `stop`. Recommend a disk-space monitor on the recorder host. |

---

## 5. Isolate-based improvements

### Current use — cache populate off the main isolate

The `/playback` cache-populate task (full-file G.711 → PCM WAV
transcode) runs on a background isolate via `Isolate.run(...)`. The
main isolate remains free to accept RTP and serve other requests while
the transcode completes.

This matters because:
- Fresh full-transcode of a 15-minute a-law recording = ~7 MB of decode
  + write work.
- Under a QA-review burst (10+ playback requests in a minute), doing
  those inline on the main isolate would introduce visible latency on
  live RTP receive.
- Isolates in Dart are pre-emptively scheduled by the VM across OS
  threads, so the recorder now scales past a single core for these
  heavy tasks without any code-path changes for the RTP recorder.

### Not moved to isolates (yet)

| Candidate | Verdict | Why |
|---|---|---|
| RTP receive → sink write | **Stay single-threaded.** | <2 % CPU at 30 concurrent calls; adding message-passing per-packet would cost more than it saves. |
| On-the-fly `/playback` transcode | Not moved yet. | Would need cross-isolate `Stream<List<int>>` piping — non-trivial. Cache-populate already absorbs the second and subsequent requests. |
| Phase 3 Opus encoding (future) | **Will use an isolate pool.** | Opus is genuinely CPU-bound (~1 % of a core per call at 24 kbps). At 30 concurrent calls + shared with RTP receive, this would saturate a single event loop. |

Nothing in the ARI client changes for §5 — it's an internal recorder
improvement.

---

## 6. Change log referenced by this doc

Commit `f7f8686` (Recording pipeline: streaming sinks, playback, and
RTP parser hardening) is the baseline for everything above.
Subsequent isolate work lands as a follow-up commit — API contract
unchanged.
