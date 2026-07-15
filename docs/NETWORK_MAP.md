# Network map — IP address inventory

Production deployment target.

---

## Hosts

| # | Role | IP | Notes |
|---|---|---|---|
| H1 | Asterisk PBX (+ ARI + MySQL) | `10.1.101.155` | Co-located with H2 and H3 |
| H2 | dart-ari client (`queue_app_main`) | `10.1.101.155` | Same box as H1 |
| H3 | **dart-rtp-recorder** | `10.1.101.155` | Same box as H1/H2 → all F1-F4 are loopback |
| H4 | MySQL (Asterisk DB) | `10.1.101.155` | Same box as H1 |
| H5 | Recording storage (`AUDIO_PATH`) | `10.1.101.155` local disk | Confirm volume / path with ops |
| H6 | Veeam backup server | `10.1.101.185` | Pulls from H5 |
| H7 | ITSP / SIP carrier | external | Existing trunk, unchanged |
| H8 | QA / supervisor subnet (playback) | _(please fill CIDR)_ | Reaches H3 over LAN |
| H9 | Agent phones subnet | _(please fill CIDR)_ | Existing SIP, unchanged |

---

## Service ports on `10.1.101.155`

| Service | Port | Protocol |
|---|---|---|
| Asterisk ARI (HTTP + WebSocket) | `8088` | TCP |
| Asterisk SIP | `5060` | UDP/TCP |
| Asterisk RTP (media) | `10000-20000` (confirm `rtp.conf`) | UDP |
| dart-ari internal HTTP | `8001` | TCP |
| **Recorder control API** | `8085` (per dart-ari `VOICE_LOGGER_PORT`) | TCP |
| Recorder RTP receive (externalMedia) | ephemeral UDP per call, assigned by recorder | UDP |
| MySQL | `3306` | TCP |

Note: recorder `.env` in this repo still has dev values
(`HTTP_SERVER_ADDRESS=10.100.54.137`, `AST_DB_HOST=10.44.0.70`,
`HTTP_SERVER_PORT=8080`). Update on the production host before deploy.

---

## Flows

| # | From | To | Purpose | Path |
|---|---|---|---|---|
| F1 | H2 dart-ari | H1 `:8088` | ARI HTTP + WebSocket | **loopback** |
| F2 | H2 dart-ari | H3 `:8085` | `POST /start`, `POST /stop` | **loopback** |
| F3 | H1 Asterisk | H3 ephemeral UDP | externalMedia RTP (a-law) | **loopback** |
| F4 | H3 recorder | H4 `:3306` | MySQL insert on finalize | **loopback** |
| F5 | Browsers (H8) | H3 `:8085` | `GET /playback` | LAN |
| F6 | H6 Veeam `10.1.101.185` | H3 storage volume | Nightly backup of `AUDIO_PATH` | LAN (1 GbE min) |
| F7 | Agents (H9) ↔ H1 | SIP + RTP | Existing call path | LAN |
| F8 | H7 ITSP ↔ H1 | SIP + RTP | Existing trunk | WAN |

---

## Please confirm

1. `AUDIO_PATH` volume on `10.1.101.155` (local NVMe? SAN? SMB mount?).
2. Subnet / CIDR for agent phones (H9) and QA workstations (H8).
3. Veeam transport mode (SMB copy from `10.1.101.185` pulling H5, or agent-based).
4. Recorder `.env` needs `HTTP_SERVER_ADDRESS=10.1.101.155` (or `0.0.0.0`) and `AST_DB_HOST=10.1.101.155` on the production box.
