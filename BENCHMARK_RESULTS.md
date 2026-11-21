# perl5-mt-shop Benchmark Results

Reference measurements for `perl5-mt-shop` running on `perl5-mt` (v5.40.2) and `mojolicious-mt` on Apple M2 Max (12 logical cores, 32 GiB RAM, macOS 27.2.1 (arm64)), collected on 2026-11-21.

These numbers represent a single-machine reference point on loopback networking. They are published to show concrete measurements across the SSHv2 transport, TUI renderer, cryptographic primitives, HTTP ops server, and database adapters, including where external hops or subprocesses add overhead. Measurements from Linux, BSD, x86_64, or POWER systems are welcome.

## Test Environment & Methodology

- **Host**: Apple M2 Max (12 logical cores, 32 GiB RAM), macOS 27.2.1 (arm64)
- **Runtime**: `perl5-mt` `v5.40.2` (shared frozen image via `MT::Image::freeze`, stackful `MT::Fiber` sessions)
- **HTTP Ops Engine**: `mojolicious-mt` (reactor `Mojo::Reactor::MT`, `Mojo::MT::Accel`: ON (Tier-1 XS))
- **HTTP Load Generator**: wrk 4.2.0 [kqueue] Copyright (C) 2012 Will Glozer (`-t4 -c64 -d5s`)
- **SQLite**: CLI `sqlite3` `3.54.0` (subprocess adapter)
- **External Backends**: IBM Db2 12.1 (SP-ONLY HTTP gateway): live (SP-ONLY); IBM Informix 15.0 (SP-ONLY HTTP gateway): live (SP-ONLY); KeyDB (127.0.0.1:6380): live (6.3.4)
- **Run Mode**: `full` (reproduce with `make all`)

### Notes & Caveats

- **Loopback contention**: The server, SSH/HTTP load generators, and Docker database containers all share the same host CPU and loopback interface.
- **Database adapters on macOS arm64**: IBM Db2 12.1 and IBM Informix 15.0 run in Linux amd64 Docker containers behind local HTTP gateways (stored-procedure-only mode) because IBM does not ship native macOS arm64 client libraries. SQLite spawns the `sqlite3` CLI per call to stay zero-XS and thread-safe.
- **Signed webhook benchmark**: `POST /webhooks/stripe` sends a validly signed Stripe event payload repeatedly. After the first delivery, subsequent requests exercise full HMAC-SHA256 verification, JSON parsing, and `MT::SharedHash` idempotency lookup without growing SQLite during the timed window.

## 1. Concurrent SSHv2 Fiber Scaling & RSS

Server booted with `4` session workers, `MT_FIBER_STACK=32768` bytes, KEX `curve25519-sha256`, cipher `chacha20-poly1305@openssh.com`, compression `zlib@openssh.com`, DB `sqlite`.

- **Baseline RSS (0 sessions)**: 107.83 MiB (110,416 KB)
- **Overall ramp**: 1,000 live sessions in 2.44 s (410.2 handshakes/s, 0 errors)
- **Post-drain**: 0 active sessions after 0.11 s, RSS 511.20 MiB (1,000 total connections)

| Live Sessions | Server RSS (MiB) | Delta vs Baseline (MiB) | KB / Fiber | Batch Handshakes/s | `/metrics` Active | Parity |
|---:|---:|---:|---:|---:|---:|:---:|
| 100 | 149.28 | 41.45 | 424.5 | 550.1 | 100 | yes |
| 250 | 209.72 | 101.89 | 417.3 | 543.6 | 250 | yes |
| 500 | 310.25 | 202.42 | 414.6 | 472.3 | 500 | yes |
| 750 | 410.64 | 302.81 | 413.4 | 381.6 | 750 | yes |
| 1,000 | 511.11 | 403.28 | 413.0 | 314.2 | 1,000 | yes |

## 2. TUI Egress & Zlib Compression Matrix

Workload: 100 interactive frames starting at 80x24 (2 resize events), backed by `MT::Array::packed('IV')`.

| Mode | Compression | Total Bytes | Bytes / Frame | Savings vs Full | Render (us/f) | Deflate (us/f) | Total CPU (us/f) | GB / 1M Sessions |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Full-frame uncompressed ANSI | none | 296,960 | 2,969.6 | 0.00% | 739.2 | 0.0 | 739.2 | 276.57 |
| Line-diff uncompressed ANSI | none | 69,750 | 697.5 | 76.51% | 744.8 | 0.0 | 744.8 | 64.96 |
| Shop::TUI::Screen cell-diff raw | none | 36,000 | 360.0 | 87.88% | 937.7 | 0.0 | 937.7 | 33.53 |
| Cell-diff + zlib@openssh.com (level 1) | zlib L1 | 4,883 | 48.8 | 98.36% | 937.7 | 3.8 | 941.5 | 4.55 |
| Cell-diff + zlib@openssh.com (level 3) | zlib L3 | 4,362 | 43.6 | 98.53% | 937.7 | 3.8 | 941.5 | 4.06 |
| Cell-diff + zlib@openssh.com (level 5) | zlib L5 | 3,899 | 39.0 | 98.69% | 937.7 | 4.6 | 942.3 | 3.63 |
| Cell-diff + zlib@openssh.com (level 6) | zlib L6 | 3,777 | 37.8 | 98.73% | 937.7 | 5.0 | 942.7 | 3.52 |
| Cell-diff + zlib@openssh.com (level 9) | zlib L9 | 3,720 | 37.2 | 98.75% | 937.7 | 7.1 | 944.8 | 3.46 |

## 3. Isolated Microbenchmarks (1, 4, 8 Workers)

Tier-1 XS in-process (`-DPERL_XS_THREADSAFE=1`): `true` | Cipher/zlib payload size: 4,096 bytes.

### 3.1 Tier-1 XS Crypto & Streaming Zlib

| Operation | Unit | 1 Worker | 4 Workers | 8 Workers | 8w / 1w Scaling |
|---|---|---:|---:|---:|---:|
| x25519 keypair+shared | ops/sec | 17,433 | 68,559 | 133,629 | 7.67x |
| mlkem768_encapsulate | ops/sec | 23,370 | 91,685 | 175,058 | 7.49x |
| ed25519_sign | ops/sec | 56,519 | 227,401 | 440,652 | 7.80x |
| ed25519_verify | ops/sec | 20,698 | 83,542 | 147,070 | 7.11x |
| chacha20-poly1305 encrypt (4K) | MB/s | 313.0 | 1,262.8 | 2,395.8 | 7.65x |
| aes256-gcm encrypt (4K) | MB/s | 2,962.4 | 10,355.4 | 16,659.6 | 5.62x |
| Zlib::deflate streaming (L5) | MB/s | 308.4 | 1,220.0 | 2,136.7 | 6.93x |

### 3.2 Lock-Free `MT::Cell` CAS Inventory Contention

| Workers | Total CAS Ops | Elapsed (s) | Ops / sec | Initial Stock | Final Stock | Zero Drift |
|---:|---:|---:|---:|---:|---:|:---:|
| 1 | 20,000 | 0.029 | 697,545 | 10,000 | 10,000 | yes |
| 2 | 40,000 | 0.031 | 1,288,660 | 10,000 | 10,000 | yes |
| 4 | 80,000 | 0.063 | 1,278,486 | 10,000 | 10,000 | yes |
| 8 | 160,000 | 0.234 | 683,711 | 10,000 | 10,000 | yes |

### 3.3 `MT::Decimal` Checkout Pricing & `Shop::TUI::Screen` Rendering

| Workload | Unit | 1 Worker | 4 Workers | 8 Workers | 8w / 1w Scaling |
|---|---|---:|---:|---:|---:|
| `MT::Decimal` checkout pricing | calcs/sec | 29,896 | 104,747 | 210,359 | 7.04x |
| `Shop::TUI::Screen` ASCII fast-path | frames/sec | 72 | 284 | 556 | 7.68x |
| `Shop::TUI::Screen` Unicode / ZWJ UAX #29 | frames/sec | 71 | 289 | 525 | 7.39x |

## 4. HTTP Ops & Webhook Throughput (`mojolicious-mt`)

Single `ops_worker` inside `bin/shop-server` (`mojolicious-mt`, reactor `Mojo::Reactor::MT`, `Mojo::MT::Accel`: ON (Tier-1 XS), cold startup to first 200 OK: 1,122.1 ms).

| Endpoint | Req / sec | Transfer (MB/s) | p50 (ms) | p95 (ms) | p99 (ms) | Requests | Errors |
|---|---:|---:|---:|---:|---:|---:|---:|
| `GET /healthz` | 5,104.3 | 1.12 | 12.44 | 13.29 | 14.63 | 26,051 | 0 |
| `GET /metrics` | 4,164.7 | 7.54 | 15.15 | 16.16 | 21.53 | 21,256 | 0 |
| `GET /api/catalog` | 3,383.9 | 13.54 | 18.64 | 19.80 | 24.47 | 16,954 | 0 |
| `POST /webhooks/stripe` | 4,511.0 | 0.77 | 13.81 | 16.53 | 25.62 | 22,626 | 0 |

## 5. Database & Cache Backend Comparison

### 5.1 SQL Backends (SQLite, IBM Db2 12.1 SP-ONLY, IBM Informix 15.0 SP-ONLY)

Each backend runs the same four operations (`list_products`, `decrement_product_stock`, `category_olap`, `tax_nexus_report`). `decrement_product_stock` restores the exact original stock after measurement so live databases remain clean.

| Backend | Operation | Ops / sec | p50 (ms) | p95 (ms) |
|---|---|---:|---:|---:|
| sqlite | `list_products` | 134.4 | 7.41 | 8.07 |
| sqlite | `decrement_product_stock` | 78.1 | 12.77 | 13.94 |
| sqlite | `category_olap` | 148.3 | 6.59 | 7.96 |
| sqlite | `tax_nexus_report` | 73.0 | 13.19 | 18.58 |
| db2 | `list_products` | 346.3 | 2.83 | 3.24 |
| db2 | `decrement_product_stock` | 22.4 | 44.36 | 46.67 |
| db2 | `category_olap` | 22.6 | 43.92 | 47.88 |
| db2 | `tax_nexus_report` | 21.6 | 45.24 | 50.21 |
| informix | `list_products` | 319.1 | 3.09 | 3.66 |
| informix | `decrement_product_stock` | 22.1 | 44.96 | 48.40 |
| informix | `category_olap` | 21.9 | 45.28 | 49.83 |
| informix | `tax_nexus_report` | 22.6 | 44.05 | 45.93 |

### 5.2 KeyDB (RESP2 Pipelining & Lua Cart Leases)

| Operation | Ops / sec | Effective Cmds / sec | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|
| `pipeline_set_get` (40 cmds/batch) | 2,161.8 batches/s | 86,472 | 0.46 | 0.54 |
| `lua_reserve_cart_lease` (`EVALSHA`) | 3,171.6 | 3,171.6 | 0.30 | 0.38 |

Backend notes:

- **SQLite 3 (CLI subprocess)**: Spawns sqlite3 CLI per call (zero-XS thread-safe adapter)
- **IBM Db2 12.1 (SP-ONLY HTTP gateway)**: Live Docker gateway at http://127.0.0.1:50050 (DB2_SP_ONLY=1, HTTP keep-alive)
- **IBM Informix 15.0 (SP-ONLY HTTP gateway)**: Live Docker gateway at http://127.0.0.1:50051 (INFORMIX_SP_ONLY=1, HTTP keep-alive)
- **KeyDB (127.0.0.1:6380)**: Live RESP2 TCP instance on 127.0.0.1:6380

## 6. Fault Tolerance & Recovery

Empirical fault-injection scenarios covering sealed boot-image isolation, `MT::Supervisor` heartbeat detection (100 ms x 3 misses), `MT::Pool` (`pairs => 1`) primary/backup checkpoint failover, per-fiber crash isolation, `MT::Checkpoint` atomic snapshots and checksum rejection, and hot-tier degradation during KeyDB and DB outages.

- **Result**: 6/6 scenarios passed (63/63 trials, 0 collateral drops)

| Scenario | Metric | Pass | p50 (ms) | p95 (ms) | Notes |
|---|---|---:|---:|---:|---|
| Sealed boot image isolation | trap + sibling ops | 5/5 | 2.732 | 2.867 | MT_IMMORTAL_MUTATION + read-only trapped; 5/5 sibling CAS+Decimal intact |
| Supervisor heartbeat detection | detection latency | 3/3 | 303.213 | 303.767 | schedule 100ms x 3 misses; healthy sibling stayed live |
| MT::Pool pairs => 1 failover | backup takeover | 5/5 | 0.029 | 0.041 | SIGSEGV on primary; backup restored checkpoint (e2e p50 1.33 ms) |
| Per-fiber crash isolation | 10-fiber batch | 10/10 | 0.583 | 0.834 | 8/10 fibers finished cleanly, 2 trapped via eval, 0 collateral drops |
| Checkpoint snapshot & checksum reject | atomic save | 20/20 | 0.306 | 0.722 | load p50 0.102 ms; corrupt byte reject p50 0.082 ms |
| Hot-tier degradation (KeyDB + DB down) | hot-tier cycle | 20/20 | 0.048 | 0.059 | KeyDB/DB closed port; catalog + CAS + Decimal + EventBus 0 errors |

## 7. Concurrency Ceiling & Interactive Latency Under Load

Server booted with `8` session workers, `MT_FIBER_STACK=32768` bytes, concurrency `32` (within macOS `kern.ipc.somaxconn=128`), KEX `curve25519-sha256`, cipher `chacha20-poly1305@openssh.com`, compression `zlib@openssh.com`, DB `sqlite`, targeting milestones `500, 1000, 2500, 5000, 7500, 10000` (reproduce with `make ceiling`). At each milestone, after a 1.0 s settle, the harness records RSS, KB/fiber, 1.0 s instantaneous steady-state idle CPU% (delta CPU time over wall time) alongside `ps %CPU`, and live interactive keypress RTT (`'j'` via `SSH_MSG_CHANNEL_DATA` to compressed ANSI diff frame response) across 10 canary sessions.

- **Baseline RSS (0 sessions)**: 114.59 MiB (117,344 KB)
- **Measured ceiling**: `bin/shop-server` stayed clean through 1,000 live sessions (0 errors, keypress RTT p95 3.05 ms) and terminated with `SIGABRT` (signal 6) at **1,018 live sessions** while ramping toward 2,500 (reproduced at 1,002 to 1,018 sessions with both 4 and 8 session workers, consistent with a process-wide 1,024-entry/FD boundary on macOS).
- **Clean drain & shutdown at peak clean milestone (1,000 sessions, `--max 1000`)**: 0 active sessions after **0.12 s**, clean `SIGTERM` shutdown in **3,824.6 ms**.

| Live Sessions | Server RSS (MiB) | KB / Fiber | Batch HS/s | Idle CPU% (1s) | `ps %CPU` | Keypress p50 (ms) | Keypress p95 (ms) | Keypress max (ms) | `/metrics` Parity | Errors |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|---:|
| 500 | 393.72 | 571.65 | 830.0 | 10.8% | 11.0% | 2.71 | 2.95 | 2.95 | OK (500) | 0 |
| 1,000 | 668.66 | 567.36 | 800.5 | 20.7% | 20.8% | 2.87 | 3.05 | 3.05 | OK (1,000) | 0 |
| 1,018 (stop) | 0.00 | 0.00 | 186.1 | 0.0% | 0.0% | n/a | n/a | n/a | server SIGABRT | 1 |

## Acknowledgments

Thank you to the Perl 5 Porters, Sebastian Riedel and the Mojolicious contributors, the libsodium, OpenSSL, and zlib maintainers, the IBM Db2, IBM Informix, KeyDB, and SQLite teams, and Will Glozer (`wrk`).
