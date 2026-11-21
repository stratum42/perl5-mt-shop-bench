#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep usleep);
use Digest::SHA qw(hmac_sha256_hex);

$SIG{PIPE} = 'IGNORE';
$| = 1;

# ---------------------------------------------------------------------------
# Paths & CLI options
# ---------------------------------------------------------------------------
my $repo_root = abs_path("$FindBin::Bin/..");
my $perl5_mt_root = $ENV{PERL5_MT_ROOT}
    || (-d "$repo_root/../perl5-mt" ? abs_path("$repo_root/../perl5-mt") : "$repo_root/../perl5-mt");
my $shop_root = $ENV{SHOP_ROOT}
    || (-d "$repo_root/../perl5-mt-shop" ? abs_path("$repo_root/../perl5-mt-shop") : "$repo_root/../perl5-mt-shop");
my $mojo_root = $ENV{MOJOLICIOUS_MT_ROOT}
    || (-d "$repo_root/../mojolicious-mt" ? abs_path("$repo_root/../mojolicious-mt") : "$repo_root/../mojolicious-mt");
my $keydb_port = defined $ENV{KEYDB_PORT} ? int($ENV{KEYDB_PORT}) : 6380;

my $opt_smoke   = 0;
my $opt_json    = '';
my $opt_no_wrk  = 0;
my $opt_dur     = 0;
my $opt_threads = 0;
my $opt_conns   = 0;

GetOptions(
    'smoke!'      => \$opt_smoke,
    'json=s'      => \$opt_json,
    'no-wrk!'     => \$opt_no_wrk,
    'duration=i'  => \$opt_dur,
    'threads=i'   => \$opt_threads,
    'conns=i'     => \$opt_conns,
) or die "Usage: $0 [--smoke] [--json path] [--no-wrk] [--duration N] [--threads N] [--conns N]\n";

my $duration = $opt_dur     || ($opt_smoke ? 2  : 5);
my $threads  = $opt_threads || ($opt_smoke ? 2  : 4);
my $conns    = $opt_conns   || ($opt_smoke ? 32 : 64);
my $warmup   = $opt_smoke ? 0.5 : 1;

my $perl5_mt_bin = "$perl5_mt_root/perl";
my $perl5_mt_lib = "$perl5_mt_root/lib";
die "perl5-mt binary not found at $perl5_mt_bin (set PERL5_MT_ROOT)\n" unless -x $perl5_mt_bin;
die "shop-server not found at $shop_root/bin/shop-server (set SHOP_ROOT)\n" unless -f "$shop_root/bin/shop-server";

# ---------------------------------------------------------------------------
# Locate wrk
# ---------------------------------------------------------------------------
sub find_wrk {
    return '' if $opt_no_wrk;
    my @candidates;
    push @candidates, $ENV{WRK_BIN} if defined $ENV{WRK_BIN} && length $ENV{WRK_BIN};
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        push @candidates, "$dir/wrk" if length $dir;
    }
    push @candidates, '/opt/homebrew/bin/wrk', '/usr/local/bin/wrk', '/usr/bin/wrk';
    for my $c (@candidates) {
        return $c if defined $c && -x $c;
    }
    return '';
}

sub free_port {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Cannot allocate ephemeral port: $!\n";
    my $p = $sock->sockport;
    close $sock;
    return $p;
}

# ---------------------------------------------------------------------------
# Boot shop-server with ephemeral SSH and ops ports
# ---------------------------------------------------------------------------
my $tmpdir    = tempdir(CLEANUP => 1);
my $ssh_port  = free_port();
my $ops_port  = free_port();
my $wh_secret = 'whsec_bench_perl5_mt_shop';

my $hostkey_path = -f "$shop_root/config/host_ed25519_key"
    ? "$shop_root/config/host_ed25519_key"
    : "$tmpdir/host_ed25519_key";

my $cfg = {
    ssh => {
        host               => '127.0.0.1',
        port               => $ssh_port,
        host_key           => $hostkey_path,
        allow_guest        => JSON::PP::true,
        compression_level  => 5,
        rate_limit_per_min => 0,
    },
    ops => {
        host           => '127.0.0.1',
        port           => $ops_port,
        webhook_secret => $wh_secret,
    },
    workers => {
        session_workers         => 2,
        db_pool_workers         => 1,
        checkpoint_interval_sec => 3600,
        lease_ttl_sec           => 900,
    },
    db => {
        driver        => 'sqlite',
        sqlite_path   => "$tmpdir/shop_bench.db",
        schema_sqlite => "$shop_root/sql/schema_sqlite.sql",
        seed_sql      => "$shop_root/sql/seed.sql",
    },
    keydb => {
        host   => '127.0.0.1',
        port   => $keydb_port,
        prefix => 'sb:',
    },
    checkpoint => {
        path => "$tmpdir/inventory.mtck",
    },
    stripe => {
        secret_key     => '',
        webhook_secret => $wh_secret,
    },
    tax_rate           => '0.0825',
    admin_fingerprints => [],
};

my $cfg_path = "$tmpdir/shop_bench.json";
open my $cfh, '>', $cfg_path or die "Cannot write $cfg_path: $!\n";
print $cfh encode_json($cfg);
close $cfh;

my $server_log = "$tmpdir/shop_server.log";
my $server_pid;

END {
    local $?;
    if (defined $server_pid && $server_pid > 0) {
        kill 'TERM', $server_pid;
        my $deadline = time() + 3;
        my $reaped = 0;
        while (time() < $deadline) {
            my $r = waitpid($server_pid, WNOHANG);
            if ($r > 0 || $r == -1) {
                $reaped = 1;
                last;
            }
            usleep(50_000);
        }
        if (!$reaped) {
            kill 'KILL', $server_pid;
            waitpid($server_pid, 0);
        }
    }
}

sub http_get_simple {
    my ($host, $port, $path) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or return (0, '');
    binmode($sock);
    my $req = "GET $path HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n\r\n";
    syswrite($sock, $req);
    my $resp = '';
    while (1) {
        my $buf;
        my $n = sysread($sock, $buf, 16384);
        last if !defined $n || $n == 0;
        $resp .= $buf;
    }
    close $sock;
    my ($hdr, $body) = split /\r\n\r\n/, $resp, 2;
    my ($code) = ($hdr // '') =~ m{^HTTP/\d+\.\d+\s+(\d+)};
    return (int($code || 0), $body // '');
}

my $t_boot = time();
$server_pid = fork();
die "fork failed: $!\n" unless defined $server_pid;
if ($server_pid == 0) {
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>', $server_log;
    open STDERR, '>&STDOUT';
    chdir $shop_root or die "chdir $shop_root: $!\n";
    local $ENV{MOJOLICIOUS_MT_ROOT}   = $mojo_root;
    local $ENV{STRIPE_WEBHOOK_SECRET} = $wh_secret;
    local $ENV{MOJO_LOG_LEVEL}        = 'error';
    local $ENV{KEYDB_PORT}            = $keydb_port;
    exec(
        $perl5_mt_bin,
        "-I$perl5_mt_lib",
        "$shop_root/bin/shop-server",
        '--config',    $cfg_path,
        '--host',      '127.0.0.1',
        '--port',      $ssh_port,
        '--ops-host',  '127.0.0.1',
        '--ops-port',  $ops_port,
        '--db-driver', 'sqlite',
    );
    die "exec shop-server failed: $!\n";
}

# Wait for /healthz
my ($health_code, $health_body, $startup_ms);
my $wait_deadline = time() + 15;
while (time() < $wait_deadline) {
    my $dead = waitpid($server_pid, WNOHANG);
    if ($dead > 0 || $dead == -1) {
        $server_pid = undef;
        open my $lfh, '<', $server_log;
        my $log = $lfh ? do { local $/; <$lfh> } : '';
        die "shop-server exited early:\n$log\n";
    }
    ($health_code, $health_body) = http_get_simple('127.0.0.1', $ops_port, '/healthz');
    if ($health_code == 200) {
        $startup_ms = (time() - $t_boot) * 1000.0;
        last;
    }
    usleep(25_000);
}
die "Timed out waiting for shop-server /healthz on 127.0.0.1:$ops_port\n" unless ($health_code // 0) == 200;

my $health = eval { decode_json($health_body) } || {};
my $engine  = $health->{engine}  // 'unknown';
my $reactor = $health->{reactor} // 'unknown';
my $accel   = $health->{accel}   ? 1 : 0;

# Build signed Stripe webhook payload
my $stripe_body = encode_json({
    id   => 'evt_bench_stripe_001',
    type => 'checkout.session.completed',
    data => {
        object => {
            id                  => 'cs_bench_001',
            client_reference_id => 'ORD-BENCH-001',
            payment_status      => 'paid',
        },
    },
});
my $stripe_ts  = int(time());
my $stripe_sig = sprintf('t=%d,v1=%s', $stripe_ts, hmac_sha256_hex("$stripe_ts.$stripe_body", $wh_secret));

my @endpoints = (
    { name => 'GET /healthz',          method => 'GET',  path => '/healthz' },
    { name => 'GET /metrics',          method => 'GET',  path => '/metrics' },
    { name => 'GET /api/catalog',      method => 'GET',  path => '/api/catalog' },
    {
        name    => 'POST /webhooks/stripe',
        method  => 'POST',
        path    => '/webhooks/stripe',
        body    => $stripe_body,
        headers => {
            'Content-Type'     => 'application/json',
            'Stripe-Signature' => $stripe_sig,
        },
    },
);

# ---------------------------------------------------------------------------
# Load generator: wrk (preferred) or multi-worker Perl HTTP/1.1 keep-alive
# ---------------------------------------------------------------------------
my $wrk_bin = find_wrk();
my $generator = length($wrk_bin) ? 'wrk' : 'perl-fallback';
my $wrk_version = '';
if ($generator eq 'wrk') {
    my $v = `$wrk_bin --version 2>&1`;
    ($wrk_version) = ($v =~ /^([^\r\n]+)/);
    $wrk_version //= 'wrk';
}

sub lua_quote {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    return '"' . $s . '"';
}

sub run_wrk_endpoint {
    my ($ep, $dur_sec) = @_;
    my $lua_path = "$tmpdir/wrk_ep.lua";
    open my $lfh, '>', $lua_path or die "Cannot write $lua_path: $!\n";
    if ($ep->{method} eq 'POST') {
        print $lfh "wrk.method = \"POST\"\n";
        for my $k (sort keys %{ $ep->{headers} || {} }) {
            print $lfh "wrk.headers[" . lua_quote($k) . "] = " . lua_quote($ep->{headers}{$k}) . "\n";
        }
        print $lfh "wrk.body = " . lua_quote($ep->{body} // '') . "\n";
    }
    print $lfh <<'LUA';
done = function(summary, latency, requests)
   local errs = summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout
   local dur_s = summary.duration / 1000000.0
   local rps = dur_s > 0 and (summary.requests / dur_s) or 0
   local mb_s = dur_s > 0 and ((summary.bytes / 1048576.0) / dur_s) or 0
   io.write(string.format(
      "BENCH_JSON:{\"requests\":%d,\"duration_s\":%.6f,\"req_per_sec\":%.2f,\"transfer_mb_s\":%.3f,\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"p99_ms\":%.3f,\"errors\":%d,\"err_connect\":%d,\"err_read\":%d,\"err_write\":%d,\"err_status\":%d,\"err_timeout\":%d}\n",
      summary.requests,
      dur_s,
      rps,
      mb_s,
      latency:percentile(50.0) / 1000.0,
      latency:percentile(95.0) / 1000.0,
      latency:percentile(99.0) / 1000.0,
      errs,
      summary.errors.connect,
      summary.errors.read,
      summary.errors.write,
      summary.errors.status,
      summary.errors.timeout
   ))
end
LUA
    close $lfh;

    my $url = "http://127.0.0.1:$ops_port$ep->{path}";
    my @cmd = ($wrk_bin, "-t$threads", "-c$conns", "-d${dur_sec}s", '-s', $lua_path, $url);
    open my $ph, '-|', @cmd or die "Failed to run wrk: $!\n";
    my $out = do { local $/; <$ph> };
    close $ph;

    my ($json_line) = ($out =~ /^BENCH_JSON:(\{.*\})$/m);
    die "Failed to parse wrk output for $ep->{name}:\n$out\n" unless defined $json_line;
    return decode_json($json_line);
}

sub percentile {
    my ($sorted, $p) = @_;
    return 0.0 unless @$sorted;
    my $idx = int(($p / 100.0) * @$sorted);
    $idx = $#$sorted if $idx > $#$sorted;
    $idx = 0 if $idx < 0;
    return $sorted->[$idx];
}

sub run_perl_fallback_endpoint {
    my ($ep, $dur_sec) = @_;
    my $workers = $threads > 0 ? $threads : 2;
    my $req = "$ep->{method} $ep->{path} HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$ops_port\r\n"
            . "Connection: keep-alive\r\n";
    if ($ep->{method} eq 'POST') {
        my $body = $ep->{body} // '';
        for my $k (sort keys %{ $ep->{headers} || {} }) {
            $req .= "$k: $ep->{headers}{$k}\r\n";
        }
        $req .= "Content-Length: " . length($body) . "\r\n\r\n" . $body;
    } else {
        $req .= "\r\n";
    }

    my @pipes;
    my @pids;
    my $t_start = time();
    for my $w (1 .. $workers) {
        pipe(my $r, my $wr) or die "pipe failed: $!\n";
        my $pid = fork();
        die "fork failed: $!\n" unless defined $pid;
        if ($pid == 0) {
            close $r;
            my $deadline = time() + $dur_sec;
            my $reqs = 0;
            my $errs = 0;
            my $bytes = 0;
            my @lats;
            my $sock;
            while (time() < $deadline) {
                if (!$sock || !$sock->connected) {
                    $sock = IO::Socket::INET->new(
                        PeerAddr => '127.0.0.1',
                        PeerPort => $ops_port,
                        Proto    => 'tcp',
                        Timeout  => 2,
                    );
                    if (!$sock) {
                        $errs++;
                        next;
                    }
                    binmode($sock);
                }
                my $t0 = time();
                my $nw = syswrite($sock, $req);
                if (!defined $nw || $nw != length($req)) {
                    $errs++;
                    close $sock;
                    $sock = undef;
                    next;
                }
                my $hdr = '';
                my $ok = 1;
                while (index($hdr, "\r\n\r\n") < 0) {
                    my $buf;
                    my $nr = sysread($sock, $buf, 4096);
                    if (!defined $nr || $nr == 0) {
                        $ok = 0;
                        last;
                    }
                    $hdr .= $buf;
                }
                if (!$ok) {
                    $errs++;
                    close $sock;
                    $sock = undef;
                    next;
                }
                my $idx = index($hdr, "\r\n\r\n");
                my $hpart = substr($hdr, 0, $idx);
                my $rest  = substr($hdr, $idx + 4);
                my ($code) = ($hpart =~ m{^HTTP/\d+\.\d+\s+(\d+)});
                my ($clen) = ($hpart =~ /Content-Length:\s*(\d+)/i);
                $clen = defined $clen ? int($clen) : 0;
                while (length($rest) < $clen) {
                    my $buf;
                    my $nr = sysread($sock, $buf, $clen - length($rest));
                    if (!defined $nr || $nr == 0) {
                        $ok = 0;
                        last;
                    }
                    $rest .= $buf;
                }
                my $dt_ms = (time() - $t0) * 1000.0;
                if (!$ok || ($code // 0) != 200) {
                    $errs++;
                    close $sock;
                    $sock = undef;
                    next;
                }
                $reqs++;
                $bytes += $idx + 4 + $clen;
                push @lats, $dt_ms if @lats < 20_000;
                if ($hpart =~ /Connection:\s*close/i) {
                    close $sock;
                    $sock = undef;
                }
            }
            close $sock if $sock;
            print $wr encode_json({ requests => $reqs, errors => $errs, bytes => $bytes, lats => \@lats });
            close $wr;
            POSIX::_exit(0);
        }
        close $wr;
        push @pipes, $r;
        push @pids,  $pid;
    }

    my ($total_reqs, $total_errs, $total_bytes) = (0, 0, 0);
    my @all_lats;
    for my $i (0 .. $#pipes) {
        my $r = $pipes[$i];
        my $raw = do { local $/; <$r> };
        close $r;
        waitpid($pids[$i], 0);
        my $d = eval { decode_json($raw) } || {};
        $total_reqs  += $d->{requests} // 0;
        $total_errs  += $d->{errors}   // 0;
        $total_bytes += $d->{bytes}    // 0;
        push @all_lats, @{ $d->{lats} || [] };
    }
    my $elapsed = time() - $t_start;
    @all_lats = sort { $a <=> $b } @all_lats;
    return {
        requests      => $total_reqs,
        duration_s    => $elapsed,
        req_per_sec   => $elapsed > 0 ? ($total_reqs / $elapsed) : 0,
        transfer_mb_s => $elapsed > 0 ? (($total_bytes / 1048576.0) / $elapsed) : 0,
        p50_ms        => percentile(\@all_lats, 50),
        p95_ms        => percentile(\@all_lats, 95),
        p99_ms        => percentile(\@all_lats, 99),
        errors        => $total_errs,
    };
}

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
print "04_http_ops_wrk: engine=$engine reactor=$reactor accel=" . ($accel ? 'true' : 'false')
    . sprintf(" startup=%.1fms generator=%s (-t%d -c%d -d%ds)\n", $startup_ms, $generator, $threads, $conns, $duration);
printf "%-24s %10s %9s %9s %9s %9s %7s\n",
    'Endpoint', 'Req/s', 'MB/s', 'p50(ms)', 'p95(ms)', 'p99(ms)', 'Errors';
printf "%-24s %10s %9s %9s %9s %9s %7s\n",
    '-' x 24, '-' x 10, '-' x 9, '-' x 9, '-' x 9, '-' x 9, '-' x 7;

my @results;
my $total_errors = 0;

for my $ep (@endpoints) {
    # Short warmup
    if ($generator eq 'wrk') {
        my $w_dur = $warmup >= 1 ? int($warmup) : 1;
        run_wrk_endpoint($ep, $w_dur);
    } else {
        run_perl_fallback_endpoint($ep, $warmup);
    }

    my $r = ($generator eq 'wrk')
        ? run_wrk_endpoint($ep, $duration)
        : run_perl_fallback_endpoint($ep, $duration);

    $total_errors += int($r->{errors} // 0);
    my $row = {
        name          => $ep->{name},
        method        => $ep->{method},
        path          => $ep->{path},
        req_per_sec   => sprintf('%.2f', $r->{req_per_sec}) + 0,
        transfer_mb_s => sprintf('%.3f', $r->{transfer_mb_s}) + 0,
        p50_ms        => sprintf('%.3f', $r->{p50_ms}) + 0,
        p95_ms        => sprintf('%.3f', $r->{p95_ms}) + 0,
        p99_ms        => sprintf('%.3f', $r->{p99_ms}) + 0,
        requests      => int($r->{requests} // 0),
        errors        => int($r->{errors} // 0),
        status_ok     => (int($r->{errors} // 0) == 0 && int($r->{requests} // 0) > 0) ? JSON::PP::true : JSON::PP::false,
    };
    push @results, $row;

    printf "%-24s %10.1f %9.2f %9.2f %9.2f %9.2f %7d\n",
        $row->{name}, $row->{req_per_sec}, $row->{transfer_mb_s},
        $row->{p50_ms}, $row->{p95_ms}, $row->{p99_ms}, $row->{errors};
}

my $payload = {
    benchmark    => '04_http_ops_wrk',
    mode         => $opt_smoke ? 'smoke' : 'full',
    generator    => $generator,
    wrk_version  => $wrk_version,
    duration_sec => $duration,
    threads      => $threads,
    connections  => $conns,
    server       => {
        engine     => $engine,
        reactor    => $reactor,
        accel      => $accel ? JSON::PP::true : JSON::PP::false,
        startup_ms => sprintf('%.2f', $startup_ms) + 0,
    },
    endpoints    => \@results,
    total_errors => $total_errors,
};

if (length $opt_json) {
    my $dir = dirname($opt_json);
    make_path($dir) if length $dir && !-d $dir;
    open my $jfh, '>', $opt_json or die "Cannot write $opt_json: $!\n";
    print $jfh JSON::PP->new->utf8->pretty->canonical->encode($payload);
    close $jfh;
}

die "HTTP ops benchmark recorded $total_errors errors\n" if $total_errors > 0;
exit 0;
