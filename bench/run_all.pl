#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use Time::HiRes qw(time);

$| = 1;

my $repo_root = abs_path("$FindBin::Bin/..");
my $perl5_mt_root = $ENV{PERL5_MT_ROOT}
    || (-d "$repo_root/../perl5-mt" ? abs_path("$repo_root/../perl5-mt") : "$repo_root/../perl5-mt");
my $shop_root = $ENV{SHOP_ROOT}
    || (-d "$repo_root/../perl5-mt-shop" ? abs_path("$repo_root/../perl5-mt-shop") : "$repo_root/../perl5-mt-shop");
my $mojo_root = $ENV{MOJOLICIOUS_MT_ROOT}
    || (-d "$repo_root/../mojolicious-mt" ? abs_path("$repo_root/../mojolicious-mt") : "$repo_root/../mojolicious-mt");

my $opt_smoke = 0;
my $opt_out   = "$repo_root/BENCHMARK_RESULTS.md";
my $opt_skip_run = 0;

GetOptions(
    'smoke!'    => \$opt_smoke,
    'out=s'     => \$opt_out,
    'skip-run!' => \$opt_skip_run,
) or die "Usage: $0 [--smoke] [--out path] [--skip-run]\n";

my $results_dir = "$repo_root/results";
make_path($results_dir);

my $perl_bin = (-x "$perl5_mt_root/perl") ? "$perl5_mt_root/perl" : $^X;
my @inc_flags;
for my $dir (
    "$perl5_mt_root/lib",
    "$shop_root/lib",
    "$shop_root/xs/Shop-SSH-Crypto/blib/lib",
    "$shop_root/xs/Shop-SSH-Crypto/blib/arch",
    "$mojo_root/lib",
    "$mojo_root/xs/blib/lib",
    "$mojo_root/xs/blib/arch",
    "$mojo_root/xs-keydb/blib/lib",
    "$mojo_root/xs-keydb/blib/arch",
) {
    push @inc_flags, "-I$dir" if -d $dir;
}

my @suites = (
    { id => '01_ssh_concurrency_rss', script => "$repo_root/bench/01_ssh_concurrency_rss.pl" },
    { id => '02_egress_matrix',       script => "$repo_root/bench/02_egress_matrix.pl" },
    { id => '03_crypto_cas_decimal',  script => "$repo_root/bench/03_crypto_cas_decimal.pl" },
    { id => '04_http_ops_wrk',        script => "$repo_root/bench/04_http_ops_wrk.pl" },
    { id => '05_databases_compare',   script => "$repo_root/bench/05_databases_compare.pl" },
    { id => '06_fault_tolerance',     script => "$repo_root/bench/06_fault_tolerance.pl" },
);

my $t_total0 = time();
if (!$opt_skip_run) {
    for my $s (@suites) {
        my $json_out = "$results_dir/$s->{id}.json";
        my @cmd = ($perl_bin, @inc_flags, $s->{script}, '--json', $json_out);
        push @cmd, '--smoke' if $opt_smoke;
        print "\n=== Running $s->{id}" . ($opt_smoke ? " (smoke)" : " (full)") . " ===\n";
        my $t0 = time();
        my $rc = system(@cmd);
        die "Suite $s->{id} failed with exit code " . ($rc >> 8) . "\n" if $rc != 0;
        printf "=== Finished $s->{id} in %.1fs ===\n", time() - $t0;
    }
}
my $total_elapsed = time() - $t_total0;

# ---------------------------------------------------------------------------
# Load JSON results
# ---------------------------------------------------------------------------
sub read_json_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json($raw);
}

my %data;
for my $s (@suites) {
    $data{ $s->{id} } = read_json_file("$results_dir/$s->{id}.json");
}

# ---------------------------------------------------------------------------
# Collect host & runtime metadata
# ---------------------------------------------------------------------------
sub run_capture {
    my ($cmd) = @_;
    my $out = `$cmd 2>/dev/null`;
    return '' unless defined $out;
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

my $os_name = run_capture('uname -s') || $^O;
my $arch    = run_capture('uname -m') || 'unknown';
my ($os_desc, $cpu_model, $cores, $ram_gb);

if ($os_name eq 'Darwin') {
    my $prod = run_capture('sw_vers -productName') || 'macOS';
    my $ver  = run_capture('sw_vers -productVersion') || '';
    $os_desc   = length($ver) ? "$prod $ver ($arch)" : "$prod ($arch)";
    $cpu_model = run_capture('sysctl -n machdep.cpu.brand_string') || 'Apple Silicon';
    $cores     = int(run_capture('sysctl -n hw.ncpu') || 0);
    my $bytes  = run_capture('sysctl -n hw.memsize') || 0;
    $ram_gb    = $bytes > 0 ? sprintf('%.0f GiB', $bytes / (1024 ** 3)) : 'unknown';
} else {
    my $rel    = run_capture('uname -r') || '';
    $os_desc   = "$os_name $rel ($arch)";
    $cpu_model = run_capture("awk -F: '/model name/{print \$2; exit}' /proc/cpuinfo") || $arch;
    $cores     = int(run_capture('nproc') || 0);
    my $kb     = run_capture("awk '/MemTotal/{print \$2; exit}' /proc/meminfo") || 0;
    $ram_gb    = $kb > 0 ? sprintf('%.0f GiB', $kb / (1024 ** 2)) : 'unknown';
}

my $perl_ver_raw = run_capture("$perl_bin -I$perl5_mt_root/lib -e 'print \$^V'");
my $perl_ver     = $perl_ver_raw || "$^V";
my $sqlite_ver   = run_capture('sqlite3 --version');
($sqlite_ver)    = ($sqlite_ver =~ /^(\S+)/) if length $sqlite_ver;
$sqlite_ver    ||= 'unknown';

my $s1 = $data{'01_ssh_concurrency_rss'};
my $s2 = $data{'02_egress_matrix'};
my $s3 = $data{'03_crypto_cas_decimal'};
my $s4 = $data{'04_http_ops_wrk'};
my $s5 = $data{'05_databases_compare'};
my $s6 = $data{'06_fault_tolerance'};

my $mode_label = $opt_smoke ? 'smoke' : 'full';
my $date_utc   = strftime('%Y-%m-%d', gmtime());

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
sub fmt_int {
    my ($n) = @_;
    return '0' unless defined $n;
    my $s = sprintf('%.0f', $n);
    while ($s =~ s/^(-?\d+)(\d{3})/$1,$2/) {}
    return $s;
}

sub fmt_dec {
    my ($n, $places) = @_;
    $places = 2 unless defined $places;
    return '0' unless defined $n;
    my $s = sprintf("%.${places}f", $n);
    my ($int, $frac) = split /\./, $s, 2;
    while ($int =~ s/^(-?\d+)(\d{3})/$1,$2/) {}
    return defined $frac ? "$int.$frac" : $int;
}

# ---------------------------------------------------------------------------
# Generate BENCHMARK_RESULTS.md
# ---------------------------------------------------------------------------
my @md;
push @md, "# perl5-mt-shop Benchmark Results\n";

if ($opt_smoke) {
    push @md, "Smoke-mode measurements for `perl5-mt-shop` on $cpu_model ($cores logical cores, $ram_gb RAM, $os_desc). Run `make all` for full reference numbers.\n";
} else {
    push @md, "Reference measurements for `perl5-mt-shop` running on `perl5-mt` ($perl_ver) and `mojolicious-mt` on $cpu_model ($cores logical cores, $ram_gb RAM, $os_desc), collected on $date_utc.\n";
}

push @md, "These numbers represent a single-machine reference point on loopback networking. They are published to show concrete measurements across the SSHv2 transport, TUI renderer, cryptographic primitives, HTTP ops server, and database adapters, including where external hops or subprocesses add overhead. Measurements from Linux, BSD, x86_64, or POWER systems are welcome.\n";

# Environment & Methodology
push @md, "## Test Environment & Methodology\n";
push @md, "- **Host**: $cpu_model ($cores logical cores, $ram_gb RAM), $os_desc";
push @md, "- **Runtime**: `perl5-mt` `$perl_ver` (shared frozen image via `MT::Image::freeze`, stackful `MT::Fiber` sessions)";
my $http_srv = $s4->{server} || {};
my $accel_str = $http_srv->{accel} ? 'ON (Tier-1 XS)' : 'OFF';
push @md, "- **HTTP Ops Engine**: `" . ($http_srv->{engine} // 'unknown') . "` (reactor `" . ($http_srv->{reactor} // 'unknown') . "`, `Mojo::MT::Accel`: $accel_str)";
my $gen_str = ($s4->{generator} // 'wrk') eq 'wrk'
    ? (($s4->{wrk_version} || 'wrk') . " (`-t$s4->{threads} -c$s4->{connections} -d$s4->{duration_sec}s`)")
    : "Built-in Perl HTTP/1.1 keep-alive (`-t$s4->{threads} -d$s4->{duration_sec}s`)";
push @md, "- **HTTP Load Generator**: $gen_str";
push @md, "- **SQLite**: CLI `sqlite3` `$sqlite_ver` (subprocess adapter)";

my @live_dbs;
for my $b (@{ $s5->{sql_backends} || [] }) {
    next if ($b->{backend} // '') eq 'sqlite';
    my $st = $b->{available} ? 'live (SP-ONLY)' : 'skipped (unavailable)';
    push @live_dbs, "$b->{label}: $st";
}
if (my $kdb = $s5->{keydb}) {
    my $kst = $kdb->{available}
        ? ("live" . (length($kdb->{version} // '') ? " ($kdb->{version})" : ''))
        : 'skipped (unavailable)';
    push @live_dbs, "$kdb->{label}: $kst";
}
push @md, "- **External Backends**: " . join('; ', @live_dbs) if @live_dbs;
push @md, "- **Run Mode**: `$mode_label` (reproduce with `" . ($opt_smoke ? 'make smoke' : 'make all') . "`)\n";

push @md, "### Notes & Caveats\n";
push @md, "- **Loopback contention**: The server, SSH/HTTP load generators, and Docker database containers all share the same host CPU and loopback interface.";
push @md, "- **Database adapters on macOS arm64**: IBM Db2 12.1 and IBM Informix 15.0 run in Linux amd64 Docker containers behind local HTTP gateways (stored-procedure-only mode) because IBM does not ship native macOS arm64 client libraries. SQLite spawns the `sqlite3` CLI per call to stay zero-XS and thread-safe.";
push @md, "- **Signed webhook benchmark**: `POST /webhooks/stripe` sends a validly signed Stripe event payload repeatedly. After the first delivery, subsequent requests exercise full HMAC-SHA256 verification, JSON parsing, and `MT::SharedHash` idempotency lookup without growing SQLite during the timed window.\n";

# Section 1: SSHv2 Fiber Scaling & RSS
push @md, "## 1. Concurrent SSHv2 Fiber Scaling & RSS\n";
my $c1 = $s1->{config} || {};
push @md, sprintf(
    "Server booted with `%d` session workers, `MT_FIBER_STACK=%d` bytes, KEX `%s`, cipher `%s`, compression `%s`, DB `%s`.\n",
    $c1->{session_workers} // 4,
    $c1->{mt_fiber_stack}  // 32768,
    $c1->{kex}             // 'curve25519-sha256',
    $c1->{cipher}          // 'chacha20-poly1305@openssh.com',
    $c1->{compression}     // 'zlib@openssh.com',
    $c1->{db_driver}       // 'sqlite',
);
push @md, sprintf(
    "- **Baseline RSS (0 sessions)**: %s MiB (%s KB)",
    fmt_dec($s1->{baseline_rss_mb}, 2), fmt_int($s1->{baseline_rss_kb})
);
push @md, sprintf(
    "- **Overall ramp**: %s live sessions in %s s (%s handshakes/s, %d errors)",
    fmt_int($c1->{max_sessions} // 0),
    fmt_dec($s1->{overall_elapsed_sec}, 2),
    fmt_dec($s1->{overall_hs_per_sec}, 1),
    int($s1->{errors} // 0)
);
if (my $pd = $s1->{post_drain}) {
    push @md, sprintf(
        "- **Post-drain**: %d active sessions after %s s, RSS %s MiB (%s total connections)\n",
        int($pd->{active_sessions} // 0),
        fmt_dec($pd->{drain_sec}, 2),
        fmt_dec($pd->{rss_mb}, 2),
        fmt_int($pd->{connections_total} // 0)
    );
}

push @md, "| Live Sessions | Server RSS (MiB) | Delta vs Baseline (MiB) | KB / Fiber | Batch Handshakes/s | `/metrics` Active | Parity |";
push @md, "|---:|---:|---:|---:|---:|---:|:---:|";
for my $m (@{ $s1->{milestones} || [] }) {
    push @md, sprintf(
        "| %s | %s | %s | %s | %s | %s | %s |",
        fmt_int($m->{sessions}),
        fmt_dec($m->{rss_mb}, 2),
        fmt_dec($m->{delta_mb}, 2),
        fmt_dec($m->{kb_per_fiber}, 1),
        fmt_dec($m->{handshakes_per_sec}, 1),
        fmt_int($m->{metrics_active}),
        $m->{metrics_parity} ? 'yes' : 'no',
    );
}
push @md, "";

# Section 2: TUI Egress & Zlib Compression Matrix
push @md, "## 2. TUI Egress & Zlib Compression Matrix\n";
my $sz = $s2->{initial_size} || { cols => 80, rows => 24 };
push @md, sprintf(
    "Workload: %d interactive frames starting at %dx%d (%d resize events), backed by `%s`.\n",
    int($s2->{frames} // 0),
    int($sz->{cols} // 80),
    int($sz->{rows} // 24),
    int($s2->{resize_events} // 0),
    $s2->{packed_array_type} // "MT::Array::packed('IV')",
);
push @md, "| Mode | Compression | Total Bytes | Bytes / Frame | Savings vs Full | Render (us/f) | Deflate (us/f) | Total CPU (us/f) | GB / 1M Sessions |";
push @md, "|---|---|---:|---:|---:|---:|---:|---:|---:|";
for my $m (@{ $s2->{modes} || [] }) {
    my $comp = ($m->{compression} // 'none') eq 'none'
        ? 'none'
        : sprintf('zlib L%d', int($m->{zlib_level} // 0));
    push @md, sprintf(
        "| %s | %s | %s | %s | %s%% | %s | %s | %s | %s |",
        $m->{label} // $m->{id},
        $comp,
        fmt_int($m->{total_bytes}),
        fmt_dec($m->{bytes_per_frame}, 1),
        fmt_dec($m->{savings_vs_full_pct}, 2),
        fmt_dec($m->{render_us_per_frame}, 1),
        fmt_dec($m->{deflate_us_per_frame}, 1),
        fmt_dec($m->{total_us_per_frame}, 1),
        fmt_dec($m->{gb_per_1m_sessions}, 2),
    );
}
push @md, "";

# Section 3: Microbenchmarks
push @md, "## 3. Isolated Microbenchmarks (1, 4, 8 Workers)\n";
push @md, "Tier-1 XS in-process (`-DPERL_XS_THREADSAFE=1`): `" . ($s3->{tier1_xs_in_process} ? 'true' : 'false')
    . "` | Cipher/zlib payload size: " . fmt_int($s3->{cipher_payload_bytes} // 4096) . " bytes.\n";

push @md, "### 3.1 Tier-1 XS Crypto & Streaming Zlib\n";
push @md, "| Operation | Unit | 1 Worker | 4 Workers | 8 Workers | 8w / 1w Scaling |";
push @md, "|---|---|---:|---:|---:|---:|";
for my $c (@{ $s3->{crypto} || [] }) {
    my $w = $c->{workers} || {};
    my $u = $c->{unit} // 'ops/sec';
    my $dec = ($u eq 'MB/s') ? 1 : 0;
    push @md, sprintf(
        "| %s | %s | %s | %s | %s | %sx |",
        $c->{label} // $c->{id},
        $u,
        fmt_dec($w->{'1'}{throughput} // 0, $dec),
        fmt_dec($w->{'4'}{throughput} // 0, $dec),
        fmt_dec($w->{'8'}{throughput} // 0, $dec),
        fmt_dec($c->{scaling_8w_1w} // 0, 2),
    );
}
push @md, "";

push @md, "### 3.2 Lock-Free `MT::Cell` CAS Inventory Contention\n";
push @md, "| Workers | Total CAS Ops | Elapsed (s) | Ops / sec | Initial Stock | Final Stock | Zero Drift |";
push @md, "|---:|---:|---:|---:|---:|---:|:---:|";
for my $r (@{ $s3->{cas_inventory} || [] }) {
    push @md, sprintf(
        "| %d | %s | %s | %s | %s | %s | %s |",
        int($r->{workers} // 0),
        fmt_int($r->{total_cas_ops}),
        fmt_dec($r->{elapsed_sec}, 3),
        fmt_int($r->{ops_per_sec}),
        fmt_int($r->{initial_stock}),
        fmt_int($r->{final_stock}),
        $r->{zero_drift} ? 'yes' : 'no',
    );
}
push @md, "";

push @md, "### 3.3 `MT::Decimal` Checkout Pricing & `Shop::TUI::Screen` Rendering\n";
push @md, "| Workload | Unit | 1 Worker | 4 Workers | 8 Workers | 8w / 1w Scaling |";
push @md, "|---|---|---:|---:|---:|---:|";
if (my $dp = $s3->{decimal_pricing}) {
    my $w = $dp->{workers} || {};
    push @md, sprintf(
        "| `MT::Decimal` checkout pricing | calcs/sec | %s | %s | %s | %sx |",
        fmt_int($w->{'1'}{calcs_per_sec} // 0),
        fmt_int($w->{'4'}{calcs_per_sec} // 0),
        fmt_int($w->{'8'}{calcs_per_sec} // 0),
        fmt_dec($dp->{scaling_8w_1w} // 0, 2),
    );
}
if (my $ts = $s3->{tui_screen}) {
    for my $pair (
        ['`Shop::TUI::Screen` ASCII fast-path',       $ts->{ascii_fast_path}],
        ['`Shop::TUI::Screen` Unicode / ZWJ UAX #29', $ts->{unicode_zwj_uax29}],
    ) {
        my ($lbl, $obj) = @$pair;
        next unless $obj && $obj->{workers};
        my $w = $obj->{workers};
        push @md, sprintf(
            "| %s | frames/sec | %s | %s | %s | %sx |",
            $lbl,
            fmt_int($w->{'1'}{frames_per_sec} // 0),
            fmt_int($w->{'4'}{frames_per_sec} // 0),
            fmt_int($w->{'8'}{frames_per_sec} // 0),
            fmt_dec($obj->{scaling_8w_1w} // 0, 2),
        );
    }
}
push @md, "";

# Section 4: HTTP Ops & Webhook Throughput
push @md, "## 4. HTTP Ops & Webhook Throughput (`mojolicious-mt`)\n";
push @md, sprintf(
    "Single `ops_worker` inside `bin/shop-server` (`%s`, reactor `%s`, `Mojo::MT::Accel`: %s, cold startup to first 200 OK: %s ms).\n",
    $http_srv->{engine} // 'unknown',
    $http_srv->{reactor} // 'unknown',
    $accel_str,
    fmt_dec($http_srv->{startup_ms} // 0, 1),
);
push @md, "| Endpoint | Req / sec | Transfer (MB/s) | p50 (ms) | p95 (ms) | p99 (ms) | Requests | Errors |";
push @md, "|---|---:|---:|---:|---:|---:|---:|---:|";
for my $ep (@{ $s4->{endpoints} || [] }) {
    push @md, sprintf(
        "| `%s` | %s | %s | %s | %s | %s | %s | %d |",
        $ep->{name},
        fmt_dec($ep->{req_per_sec}, 1),
        fmt_dec($ep->{transfer_mb_s}, 2),
        fmt_dec($ep->{p50_ms}, 2),
        fmt_dec($ep->{p95_ms}, 2),
        fmt_dec($ep->{p99_ms}, 2),
        fmt_int($ep->{requests}),
        int($ep->{errors} // 0),
    );
}
push @md, "";

# Section 5: Database & Cache Backend Comparison
push @md, "## 5. Database & Cache Backend Comparison\n";
push @md, "### 5.1 SQL Backends (SQLite, IBM Db2 12.1 SP-ONLY, IBM Informix 15.0 SP-ONLY)\n";
push @md, "Each backend runs the same four operations (`list_products`, `decrement_product_stock`, `category_olap`, `tax_nexus_report`). `decrement_product_stock` restores the exact original stock after measurement so live databases remain clean.\n";

push @md, "| Backend | Operation | Ops / sec | p50 (ms) | p95 (ms) |";
push @md, "|---|---|---:|---:|---:|";
my @sql_ops = qw(list_products decrement_product_stock category_olap tax_nexus_report);
my @db_notes;
for my $b (@{ $s5->{sql_backends} || [] }) {
    push @db_notes, "- **$b->{label}**: $b->{note}" if length($b->{note} // '');
    if (!$b->{available}) {
        push @md, "| $b->{label} | _(skipped)_ | - | - | - |";
        next;
    }
    for my $op (@sql_ops) {
        my $r = $b->{ops}{$op} or next;
        push @md, sprintf(
            "| %s | `%s` | %s | %s | %s |",
            $b->{backend},
            $op,
            fmt_dec($r->{ops_sec}, 1),
            fmt_dec($r->{p50_ms}, 2),
            fmt_dec($r->{p95_ms}, 2),
        );
    }
}
push @md, "";

push @md, "### 5.2 KeyDB (RESP2 Pipelining & Lua Cart Leases)\n";
if (my $kdb = $s5->{keydb}) {
    push @db_notes, "- **$kdb->{label}**: $kdb->{note}" if length($kdb->{note} // '');
    if (!$kdb->{available}) {
        push @md, "_KeyDB skipped: $kdb->{note}_\n";
    } else {
        push @md, "| Operation | Ops / sec | Effective Cmds / sec | p50 (ms) | p95 (ms) |";
        push @md, "|---|---:|---:|---:|---:|";
        if (my $pr = $kdb->{ops}{pipeline_set_get}) {
            push @md, sprintf(
                "| `pipeline_set_get` (%d cmds/batch) | %s batches/s | %s | %s | %s |",
                int($pr->{cmds_per_batch} // 40),
                fmt_dec($pr->{ops_sec}, 1),
                fmt_int($pr->{cmds_sec}),
                fmt_dec($pr->{p50_ms}, 2),
                fmt_dec($pr->{p95_ms}, 2),
            );
        }
        if (my $lr = $kdb->{ops}{lua_reserve_cart_lease}) {
            push @md, sprintf(
                "| `lua_reserve_cart_lease` (`EVALSHA`) | %s | %s | %s | %s |",
                fmt_dec($lr->{ops_sec}, 1),
                fmt_dec($lr->{ops_sec}, 1),
                fmt_dec($lr->{p50_ms}, 2),
                fmt_dec($lr->{p95_ms}, 2),
            );
        }
        push @md, "";
    }
}

if (@db_notes) {
    push @md, "Backend notes:\n";
    push @md, @db_notes;
    push @md, "";
}

# Section 6: Fault Tolerance & Recovery
if ($s6 && ref($s6->{scenarios}) eq 'ARRAY') {
    my $sum6 = $s6->{summary} || {};
    my $hb6  = $s6->{heartbeat_config} || {};
    push @md, "## 6. Fault Tolerance & Recovery\n";
    push @md, sprintf(
        "Empirical fault-injection scenarios covering sealed boot-image isolation, `MT::Supervisor` heartbeat detection (%d ms x %d misses), `MT::Pool` (`pairs => 1`) primary/backup checkpoint failover, per-fiber crash isolation, `MT::Checkpoint` atomic snapshots and checksum rejection, and hot-tier degradation during KeyDB and DB outages.\n",
        int($hb6->{heartbeat_ms}   // 100),
        int($hb6->{heartbeat_miss} // 3),
    );
    push @md, sprintf(
        "- **Result**: %d/%d scenarios passed (%d/%d trials, %d collateral drops)\n",
        int($sum6->{scenarios_passed} // 0),
        int($sum6->{scenarios_total}  // 0),
        int($sum6->{trials_passed}    // 0),
        int($sum6->{trials_total}     // 0),
        int($sum6->{collateral_drops} // 0),
    );
    push @md, "| Scenario | Metric | Pass | p50 (ms) | p95 (ms) | Notes |";
    push @md, "|---|---|---:|---:|---:|---|";
    for my $sc (@{ $s6->{scenarios} }) {
        push @md, sprintf(
            "| %s | %s | %d/%d | %s | %s | %s |",
            $sc->{label}  // $sc->{id},
            $sc->{metric} // '-',
            int($sc->{passed} // 0),
            int($sc->{trials} // 0),
            fmt_dec($sc->{p50_ms}, 3),
            fmt_dec($sc->{p95_ms}, 3),
            $sc->{detail} // '',
        );
    }
    push @md, "";
}

push @md, "## Acknowledgments\n";
push @md, "Thank you to the Perl 5 Porters, Sebastian Riedel and the Mojolicious contributors, the libsodium, OpenSSL, and zlib maintainers, the IBM Db2, IBM Informix, KeyDB, and SQLite teams, and Will Glozer (`wrk`).\n";

my $out_dir = dirname($opt_out);
make_path($out_dir) if length $out_dir && !-d $out_dir;
open my $ofh, '>:encoding(UTF-8)', $opt_out or die "Cannot write $opt_out: $!\n";
print $ofh join("\n", @md);
close $ofh;

printf "\nWrote %s (total elapsed: %.1fs)\n", $opt_out, $total_elapsed;
exit 0;
