# Network map — IP address inventory

One-page sheet for the networks team: name the hosts and record their
IP addresses. All values marked `?` need confirmation.

Sources pre-filled from:
- `dart-rtp-recorder/.env` (recorder host)
- `C:\www\dart\dart-ari\.env` (ARI client host)

Note: the two `.env` files currently disagree on the recorder's IP —
recorder binds `10.100.54.137`, dart-ari has `VOICE_LOGGER_IP=10.1.101.155`.
Please confirm the correct value in production.

---

## Hosts

| # | Role | Hostname | IP | NIC / VLAN |
|---|---|---|---|---|
| H1 | Asterisk PBX (+ ARI, + MySQL — currently co-located per dart-ari `.env`) | ? | `10.1.101.155` | ? |
| H2 | dart-ari client (queue_app_main) | ? | ? _(same host as H1?)_ | ? |
| H3 | **dart-rtp-recorder** | ? | `10.100.54.137` _(from recorder `.env`)_ **or** `10.1.101.155` _(from dart-ari `.env`)_ — reconcile | ? |
| H4 | MySQL (Asterisk DB) | ? | `10.44.0.70` _(recorder .env)_ **or** `10.1.101.155` _(dart-ari .env)_ — reconcile | ? |
| H5 | Recording storage (if separate from H3) | ? | ? | ? |
| H6 | Veeam backup server | ? | ? | ? |
| H7 | ITSP / SIP carrier CPE (if on-prem) | ? | ? | ? |
| H8 | QA / supervisor subnet (playback clients) | n/a | ?/?? _(CIDR)_ | ? |
| H9 | Agent phones subnet | n/a | ?/?? _(CIDR)_ | ? |

---

## Service ports

| Host | Service | Port | Protocol | Source of truth |
|---|---|---|---|---|
| H1 | Asterisk ARI (HTTP + WebSocket) | `8088` | TCP | dart-ari `ASTERISK_ARI_PORT` |
| H1 | Asterisk SIP | `5060` | UDP/TCP | seen in dart-ari `endpoint_push.dart` |
| H1 | Asterisk RTP (media) | `10000-20000` _(default; confirm)_ | UDP | Asterisk `rtp.conf` |
| H2 | dart-ari internal HTTP | `8001` | TCP | dart-ari `SERVER_PORT` |
| H3 | Recorder control API | `8085` _(dart-ari)_ / **confirm** in recorder `.env` `HTTP_SERVER_PORT` | TCP | dart-ari `VOICE_LOGGER_PORT` |
| H3 | Recorder RTP receive (externalMedia) | ephemeral UDP per call, assigned by recorder in `/start` reply | UDP | `RawDatagramSocket.bind(ip, 0)` in `worker_pool.dart` |
| H4 | MySQL | `3306` | TCP | recorder `.env` `AST_DB_PORT` |
| H6 | Veeam (data mover) | `2500-3300` _(default range)_ | TCP | Veeam config |

---

## Flows (who talks to whom)

| # | From | To | Purpose |
|---|---|---|---|
| F1 | H2 dart-ari | H1 `:8088` | ARI HTTP + WebSocket (control + Stasis events) |
| F2 | H2 dart-ari | H3 `:HTTP_SERVER_PORT` | `POST /start`, `POST /stop` |
| F3 | H1 Asterisk | H3 ephemeral UDP | RTP media stream (externalMedia, a-law) |
| F4 | H3 recorder | H4 `:3306` | MySQL insert on call finalize |
| F5 | Browsers (H8) | H3 `:HTTP_SERVER_PORT` | `GET /playback?filename=X` |
| F6 | H6 Veeam | H3 / H5 storage volume | Nightly backup of `AUDIO_PATH` |
| F7 | Agents (H9) ↔ H1 | H1 SIP+RTP | Existing call path (unchanged) |
| F8 | H7 ITSP ↔ H1 | H1 SIP+RTP | Existing trunk (unchanged) |

---

## Please confirm

1. Are H1, H2, H4 the same physical box? (dart-ari `.env` suggests yes — all `10.1.101.155`.)
2. What is the recorder's actual production IP? (recorder `.env` says `10.100.54.137`; dart-ari `.env` says `10.1.101.155`.)
3. Is the MySQL at `10.44.0.70` (recorder view) or `10.1.101.155` (dart-ari view)? One of the `.env` files is stale.
4. Subnet / CIDR for agent phones (H9) and QA workstations (H8).
5. Veeam server IP (H6) and whether it uses a dedicated backup VLAN.
