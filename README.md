# perl5-mt-shop-bench

Reproducible benchmark harnesses and reference measurements for [`perl5-mt-shop`](../perl5-mt-shop) running on [`perl5-mt`](../perl5-mt) and [`mojolicious-mt`](../mojolicious-mt).

This repository measures the core subsystems of `perl5-mt-shop` end to end: concurrent SSHv2 fiber scaling and RSS footprint, ANSI TUI egress and zlib compression tradeoffs, Tier-1 XS crypto and lock-free `MT::Cell` / `MT::Decimal` scaling, HTTP ops and webhook throughput under `mojolicious-mt`, and database round-trip latency across SQLite, IBM Db2, IBM Informix, and KeyDB.

## Acknowledgments

This benchmark suite builds on the work of many communities and maintainers:

- **Perl 5** and the Perl 5 Porters, for the language, runtime, and core libraries.
- **Mojolicious** (Sebastian Riedel and the Mojolicious contributors), for the web framework powering the ops and webhook HTTP plane.
- **libsodium**, **OpenSSL**, and **zlib**, for the cryptographic primitives and stream compression used by the SSHv2 transport.
- **IBM Db2**, **IBM Informix**, **KeyDB** (and the Redis / RESP2 ecosystem), and **SQLite**, for the storage and caching engines tested here.
- **Will Glozer (`wrk`)**, for the HTTP load generator used in the ops benchmark.

## What Is Included

1. **`bench/01_ssh_concurrency_rss.pl`**: Boots `bin/shop-server` on ephemeral ports with `MT_FIBER_STACK=32768` and opens concurrent real SSHv2 sessions (`curve25519-sha256` + `chacha20-poly1305@openssh.com` + `zlib@openssh.com` + PTY + initial ANSI TUI render) up to 1,000 live fibers (100 in `--smoke` mode). Records baseline RSS, milestone RSS (100, 250, 500, 750, 1,000), KB per fiber, handshakes/sec, `/metrics` active-session parity, and post-drain RSS.
2. **`bench/02_egress_matrix.pl`**: Drives a 100-frame 80x24 interactive TUI workload (30 frames in `--smoke` mode) covering initial render, catalog navigation, live stock updates, cart updates, and terminal resize. Compares full-frame ANSI, line-diff ANSI, `Shop::TUI::Screen` cell-diff (`MT::Array::packed('IV')`) raw, and cell-diff with `zlib@openssh.com` across compression levels 1, 3, 5, 6, and 9, measuring both exact wire bytes and CPU microseconds per frame.
3. **`bench/03_crypto_cas_decimal.pl`**: Isolated multi-worker microbenchmarks (1, 4, and 8 `MT::Worker` threads) covering Tier-1 XS crypto (`x25519`, `mlkem768_encapsulate`, `ed25519_sign`/`verify`, `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, streaming `zlib`), lock-free `MT::Cell` CAS inventory contention with zero-drift verification, `MT::Decimal` checkout pricing, and `Shop::TUI::Screen` ASCII fast-path versus UAX #29 Unicode/ZWJ rendering.
4. **`bench/04_http_ops_wrk.pl`**: Boots `bin/shop-server` with `mojolicious-mt` (`Mojo::Reactor::MT` + `Mojo::MT::Accel`) on ephemeral SSH and ops ports and benchmarks `GET /healthz`, `GET /metrics`, `GET /api/catalog`, and signed `POST /webhooks/stripe` using `wrk` (with a built-in multi-worker Perl HTTP/1.1 keep-alive fallback if `wrk` is not installed).
5. **`bench/05_databases_compare.pl`**: Benchmarks identical operations (`list_products`, `decrement_product_stock` with exact stock restoration afterward, `category_olap`, `tax_nexus_report`) across SQLite, live IBM Db2 12.1 SP-ONLY (`http://127.0.0.1:50050`), and live IBM Informix 15.0 SP-ONLY (`http://127.0.0.1:50051`), plus KeyDB pipelined `SET`/`GET` and Lua `reserve_cart_lease`. Unavailable Docker or KeyDB backends are skipped cleanly with a note.
6. **`bench/06_fault_tolerance.pl`**: Runs six empirical fault-injection and chaos scenarios: sealed boot-image mutation trapping alongside healthy sibling CAS/Decimal work, `MT::Supervisor` + `MT::Fault` missed-heartbeat detection, `MT::Pool` (`pairs => 1`) primary/backup checkpoint failover on primary `SIGSEGV`, per-fiber crash isolation across 10 fibers, `MT::Checkpoint` atomic snapshot save/reload and corrupted-byte checksum rejection, and hot-tier graceful degradation during KeyDB and DB outages.
7. **`bench/07_concurrency_ceiling.pl`**: Ramps live real SSHv2 sessions (`curve25519-sha256`, `chacha20-poly1305@openssh.com`, `zlib@openssh.com`, PTY, initial TUI render) with 8 session workers, `MT_FIBER_STACK=32768`, and 32 concurrent handshakes across milestones (`500, 1000, 2500, 5000, 7500, 10000`; `250, 500` in `--smoke` mode). At each milestone after a 1.0 s settle, records server RSS, KB/fiber, 1.0 s steady-state idle CPU% alongside `ps %CPU`, live interactive keypress RTT (`'j'` across 10 canary sessions: p50, p95, max), `/metrics` parity, and error count, stopping cleanly on errors or p95 keypress RTT above 500 ms, then measures full session drain and clean `SIGTERM` shutdown time.
8. **`bench/run_all.pl`**: Runs `01` through `06` in sequence, writes per-suite JSON artifacts under `results/`, collects host and runtime metadata, and generates [`BENCHMARK_RESULTS.md`](BENCHMARK_RESULTS.md).

## Reference Report

- [`BENCHMARK_RESULTS.md`](BENCHMARK_RESULTS.md): Full single-machine reference measurements generated by `make all`.

## Prerequisites

- Sibling checkouts of `perl5-mt` (built), `perl5-mt-shop` (with XS `Shop::SSH::Crypto` built via `make`), and `mojolicious-mt` (with `xs/` built for `Mojo::MT::Accel`), or explicit overrides via the environment variables below.
- `sqlite3` on `PATH` (for the SQLite adapter).
- Optional: `wrk` on `PATH` (for `bench/04_http_ops_wrk.pl`; falls back to a built-in Perl HTTP/1.1 keep-alive generator when absent).
- Optional: live IBM Db2 12.1 SP-ONLY gateway (`127.0.0.1:50050`), live IBM Informix 15.0 SP-ONLY gateway (`127.0.0.1:50051`), and live KeyDB (`127.0.0.1:6380` or `KEYDB_PORT`) for `bench/05_databases_compare.pl`.

## Quick Start

Run from the root of `perl5-mt-shop-bench`:

```sh
# Fast end-to-end smoke check (short durations, 100 SSH fibers)
KEYDB_PORT=6380 make smoke

# Full benchmark suite (1,000 SSH fibers + all subsystems; writes BENCHMARK_RESULTS.md)
KEYDB_PORT=6380 make all
```

Individual benchmarks can also be run directly, for example:

```sh
perl bench/04_http_ops_wrk.pl --smoke --json results/04_http_ops_wrk.json
KEYDB_PORT=6380 perl bench/05_databases_compare.pl --smoke --json results/05_databases_compare.json
make fault
make ceiling
```

## Environment Variables

All harnesses default to sibling checkouts (`../perl5-mt`, `../perl5-mt-shop`, `../mojolicious-mt`) and accept overrides for any local layout:

| Variable | Default | Description |
|---|---|---|
| `PERL5_MT_ROOT` | `../perl5-mt` | Path to the built `perl5-mt` directory containing `perl` and `lib/`. |
| `SHOP_ROOT` | `../perl5-mt-shop` | Path to the `perl5-mt-shop` repository. |
| `MOJOLICIOUS_MT_ROOT` | `../mojolicious-mt` | Path to the `mojolicious-mt` repository (`lib/` and `xs/blib`). |
| `KEYDB_HOST` | `127.0.0.1` | Hostname for the KeyDB / RESP2 instance. |
| `KEYDB_PORT` | `6380` | TCP port for the KeyDB / RESP2 instance. |
| `DB2_GATEWAY_URL` | `http://127.0.0.1:50050` | URL for the IBM Db2 SP-ONLY HTTP gateway. |
| `INFORMIX_GATEWAY_URL` | `http://127.0.0.1:50051` | URL for the IBM Informix SP-ONLY HTTP gateway. |
| `WRK_BIN` | `wrk` in `PATH` | Explicit path to the `wrk` binary. |

## Caveats

- **Single-machine loopback reference**: The published numbers in `BENCHMARK_RESULTS.md` are collected on a single Apple Silicon (macOS arm64) host where the server, load generators, and database containers share CPU and loopback networking. Different operating systems, kernel socket models, CPU architectures, and network topologies will produce different numbers.
- **Database transport differences**: On macOS arm64, IBM Db2 and IBM Informix run inside Linux amd64 Docker containers behind local HTTP gateways (because IBM does not distribute native macOS arm64 CLI/ODBC drivers), while the SQLite adapter spawns the `sqlite3` CLI per call to stay zero-XS and thread-safe. Native C drivers on Linux x86_64, ppc64le, or AIX will have lower per-query overhead.
- **Webhook benchmark path**: `POST /webhooks/stripe` sends a validly signed Stripe event payload repeatedly; after the first delivery, subsequent requests exercise full HMAC-SHA256 signature verification, JSON decoding, and `MT::SharedHash` idempotency lookup without growing the SQLite database during the load window.
- **Community measurements**: If you run this suite on a quiet Linux, BSD, x86_64, or POWER system, your numbers and observations are welcome.
