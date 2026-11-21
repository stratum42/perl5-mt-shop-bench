#!/usr/bin/env perl
use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my ($BENCH_ROOT, $PERL_ROOT, $SHOP_ROOT, $MOJO_ROOT);
BEGIN {
    $BENCH_ROOT = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
    my $parent  = File::Spec->rel2abs(File::Spec->catdir($BENCH_ROOT, '..'));
    $PERL_ROOT  = $ENV{PERL5_MT_ROOT}       // File::Spec->catdir($parent, 'perl5-mt');
    $SHOP_ROOT  = $ENV{SHOP_ROOT}           // File::Spec->catdir($parent, 'perl5-mt-shop');
    $MOJO_ROOT  = $ENV{MOJOLICIOUS_MT_ROOT} // File::Spec->catdir($parent, 'mojolicious-mt');

    for my $dir (
        "$MOJO_ROOT/xs-keydb/blib/arch",
        "$MOJO_ROOT/xs-keydb/blib/lib",
        "$MOJO_ROOT/xs/blib/arch",
        "$MOJO_ROOT/xs/blib/lib",
        "$MOJO_ROOT/lib",
        "$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/arch",
        "$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/lib",
        "$SHOP_ROOT/lib",
        "$PERL_ROOT/lib",
    ) {
        unshift @INC, $dir if -d $dir && !grep { $_ eq $dir } @INC;
    }
}

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use IO::Socket::INET;
use IO::Poll qw(POLLIN POLLOUT POLLERR POLLHUP);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR EINPROGRESS);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC usleep);
use POSIX ();

use Shop::SSH::Crypto qw(
    random_bytes
    x25519_keypair
    x25519_shared
    ed25519_verify
    sha256
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_len
    chacha20_poly1305_openssh_decrypt_body
);
use Shop::SSH::Wire qw(:all);

$SIG{PIPE} = 'IGNORE';
$| = 1;

my $max_sessions    = 10000;
my $max_explicit    = 0;
my $concurrency     = 32;
my $session_workers = 8;
my $fiber_stack     = 32768;
my $num_canaries    = 10;
my $rtt_limit_ms    = 500.0;
my $smoke           = 0;
my $json_path       = '';

GetOptions(
    'max=i'             => sub { $max_sessions = $_[1]; $max_explicit = 1; },
    'concurrency=i'     => \$concurrency,
    'session-workers=i' => \$session_workers,
    'fiber-stack=i'     => \$fiber_stack,
    'canaries=i'        => \$num_canaries,
    'rtt-limit-ms=f'    => \$rtt_limit_ms,
    'smoke!'            => \$smoke,
    'json=s'            => \$json_path,
) or die "Usage: $0 [--max N] [--concurrency N] [--session-workers N] [--fiber-stack bytes] [--canaries N] [--rtt-limit-ms ms] [--smoke] [--json path]\n";

if ($smoke && !$max_explicit) {
    $max_sessions = 500;
}
$max_sessions = 1 if $max_sessions < 1;
$concurrency  = 1 if $concurrency < 1;
$concurrency  = $max_sessions if $concurrency > $max_sessions;
$num_canaries = $max_sessions if $num_canaries > $max_sessions;
$num_canaries = 1 if $num_canaries < 1;

# Build milestone schedule
my @milestones;
if ($smoke && !$max_explicit) {
    @milestones = (250, 500);
} else {
    my @std = (500, 1000, 2500, 5000, 7500, 10000);
    @milestones = grep { $_ <= $max_sessions } @std;
    push @milestones, $max_sessions if !@milestones || $milestones[-1] != $max_sessions;
}

# ---------------------------------------------------------------------------
# Helpers: ephemeral ports, RSS, CPU, percentiles, HTTP /healthz & /metrics
# ---------------------------------------------------------------------------
sub pick_ephemeral_port {
    my $s = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Cannot bind ephemeral port: $!\n";
    my $port = $s->sockport;
    close($s);
    return $port;
}

sub measure_rss_kb {
    my ($pid) = @_;
    if (open my $fh, '<', "/proc/$pid/status") {
        while (<$fh>) {
            if (/^VmRSS:\s+(\d+)\s+kB/) {
                close $fh;
                return int($1);
            }
        }
        close $fh;
    }
    my $out = `ps -o rss= -p $pid 2>/dev/null`;
    if (defined $out && $out =~ /(\d+)/) {
        return int($1);
    }
    return 0;
}

sub _parse_ps_time_sec {
    my ($str) = @_;
    return undef unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    if ($str =~ /^(\d+)-(\d+):(\d+):(\d+(?:\.\d+)?)$/) {
        return $1 * 86400 + $2 * 3600 + $3 * 60 + $4;
    }
    if ($str =~ /^(\d+):(\d+):(\d+(?:\.\d+)?)$/) {
        return $1 * 3600 + $2 * 60 + $3;
    }
    if ($str =~ /^(\d+):(\d+(?:\.\d+)?)$/) {
        return $1 * 60 + $2;
    }
    return undef;
}

sub measure_cpu_time_sec {
    my ($pid) = @_;
    if (open my $fh, '<', "/proc/$pid/stat") {
        my $line = <$fh>;
        close $fh;
        if (defined $line && $line =~ /\)\s+\S+\s+(.*)/) {
            my @fields = split /\s+/, $1;
            # fields[10] = utime (14th), fields[11] = stime (15th)
            if (defined $fields[10] && defined $fields[11]) {
                my $clk = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
                return ($fields[10] + $fields[11]) / $clk;
            }
        }
    }
    my $out = `ps -o time= -p $pid 2>/dev/null`;
    return _parse_ps_time_sec($out);
}

sub measure_ps_pcpu {
    my ($pid) = @_;
    my $out = `ps -o %cpu= -p $pid 2>/dev/null`;
    if (defined $out && $out =~ /(\d+(?:\.\d+)?)/) {
        return $1 + 0.0;
    }
    return 0.0;
}

sub percentile {
    my ($arr, $p) = @_;
    return 0.0 unless @$arr;
    my @sorted = sort { $a <=> $b } @$arr;
    my $idx = int(($p / 100.0) * $#sorted + 0.5);
    $idx = 0 if $idx < 0;
    $idx = $#sorted if $idx > $#sorted;
    return $sorted[$idx];
}

sub http_get {
    my ($host, $port, $path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or return undef;
    print $s "GET $path HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n\r\n";
    local $/;
    my $raw = <$s>;
    close($s);
    return undef unless defined $raw;
    my ($hdr, $body) = split /\r\n\r\n/, $raw, 2;
    return ($hdr // '', $body // '');
}

sub fetch_metrics {
    my ($host, $port) = @_;
    my ($hdr, $body) = http_get($host, $port, '/metrics');
    return {} unless defined $body;
    my %m;
    for my $line (split /\r?\n/, $body) {
        next if $line =~ /^#/ || $line !~ /\S/;
        if ($line =~ /^([a-zA-Z0-9_:]+)\s+(-?\d+(?:\.\d+)?)/) {
            $m{$1} = $2 + 0;
        }
    }
    return \%m;
}

# ---------------------------------------------------------------------------
# Start bin/shop-server in isolated temp workspace
# ---------------------------------------------------------------------------
my $tmp_dir   = tempdir(CLEANUP => 1);
my $ssh_port  = pick_ephemeral_port();
my $ops_port  = pick_ephemeral_port();
my $cfg_path  = "$tmp_dir/shop_ceiling.json";
my $db_path   = "$tmp_dir/shop_ceiling.sqlite";
my $ckpt_path = "$tmp_dir/inventory.mtck";
my $hostkey_p = "$SHOP_ROOT/config/host_ed25519_key";
$hostkey_p    = "$tmp_dir/host_ed25519_key" unless -f $hostkey_p;
my $srv_log   = "$tmp_dir/shop_server.log";

my $cfg = {
    ssh => {
        host               => '127.0.0.1',
        port               => int($ssh_port),
        host_key           => $hostkey_p,
        allow_guest        => JSON::PP::true,
        compression_level  => 5,
        rate_limit_per_min => 0,
    },
    ops => {
        host           => '127.0.0.1',
        port           => int($ops_port),
        webhook_secret => 'whsec_bench_test',
    },
    workers => {
        session_workers         => int($session_workers),
        db_pool_workers         => 2,
        checkpoint_interval_sec => 3600,
        lease_ttl_sec           => 900,
    },
    db => {
        driver        => 'sqlite',
        sqlite_path   => $db_path,
        schema_sqlite => "$SHOP_ROOT/sql/schema_sqlite.sql",
        seed_sql      => "$SHOP_ROOT/sql/seed.sql",
    },
    keydb => {
        host   => '127.0.0.1',
        port   => 1,
        prefix => 'bench:',
    },
    checkpoint => {
        path => $ckpt_path,
    },
    stripe => {
        secret_key     => '',
        webhook_secret => 'whsec_bench_test',
    },
    tax_rate           => '0.0825',
    admin_fingerprints => [],
};

open my $cfh, '>', $cfg_path or die "Cannot write $cfg_path: $!\n";
print $cfh JSON::PP->new->utf8->pretty->encode($cfg);
close $cfh;

my $server_pid;
END {
    local $?;
    if (defined $server_pid && $server_pid > 0) {
        kill 'TERM', $server_pid;
        for (1 .. 100) {
            my $r = waitpid($server_pid, POSIX::WNOHANG());
            last if $r == $server_pid || $r < 0;
            usleep(50_000);
        }
        kill 'KILL', $server_pid if kill(0, $server_pid);
        waitpid($server_pid, 0);
    }
}

my $perl_bin = $^X;
my @srv_cmd = (
    $perl_bin,
    "-I$PERL_ROOT/lib",
    "-I$SHOP_ROOT/lib",
    "-I$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/lib",
    "-I$SHOP_ROOT/xs/Shop-SSH-Crypto/blib/arch",
    (-d "$MOJO_ROOT/lib" ? (
        "-I$MOJO_ROOT/lib",
        "-I$MOJO_ROOT/xs/blib/lib",
        "-I$MOJO_ROOT/xs/blib/arch",
        "-I$MOJO_ROOT/xs-keydb/blib/lib",
        "-I$MOJO_ROOT/xs-keydb/blib/arch",
    ) : ()),
    "$SHOP_ROOT/bin/shop-server",
    '--config', $cfg_path,
);

$server_pid = fork();
die "fork failed: $!\n" unless defined $server_pid;
if ($server_pid == 0) {
    $ENV{MT_FIBER_STACK} = $fiber_stack;
    open STDOUT, '>', $srv_log or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    exec @srv_cmd or die "exec shop-server failed: $!\n";
}

# Wait for /healthz to respond 200 OK
my $ready = 0;
for (1 .. 150) {
    if (waitpid($server_pid, POSIX::WNOHANG()) > 0) {
        $server_pid = undef;
        my $log = do { local $/; open my $lf, '<', $srv_log; $lf ? <$lf> : '' };
        die "bin/shop-server exited prematurely:\n$log\n";
    }
    my ($hdr, $body) = http_get('127.0.0.1', $ops_port, '/healthz');
    if (defined $hdr && $hdr =~ m{HTTP/1\.[01]\s+200}) {
        $ready = 1;
        last;
    }
    usleep(100_000);
}
die "Timed out waiting for bin/shop-server on 127.0.0.1:$ops_port\n" unless $ready;
usleep(300_000);

my $baseline_rss_kb = measure_rss_kb($server_pid);

# ---------------------------------------------------------------------------
# Minimal real SSHv2 client (curve25519-sha256 + chacha20-poly1305 + zlib)
# Supports canary mode (retains crypto + zlib state for live keypress probes)
# ---------------------------------------------------------------------------
package CeilingSSHClient;
use strict;
use warnings;
use IO::Socket::INET;
use IO::Poll qw(POLLIN POLLOUT);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Shop::SSH::Crypto qw(
    random_bytes
    x25519_keypair
    x25519_shared
    ed25519_verify
    sha256
    chacha20_poly1305_openssh_encrypt
    chacha20_poly1305_openssh_decrypt_len
    chacha20_poly1305_openssh_decrypt_body
);
use Shop::SSH::Wire qw(:all);

my $CLIENT_VERSION = 'SSH-2.0-perl5-mt-shop-ceiling';

sub _derive_key {
    my ($K_encoded, $H, $letter, $session_id, $need) = @_;
    my $k = sha256($K_encoded . $H . $letter . $session_id);
    while (length($k) < $need) {
        $k .= sha256($K_encoded . $H . $k);
    }
    return substr($k, 0, $need);
}

sub _build_client_kexinit {
    return pack_byte(SSH_MSG_KEXINIT)
         . random_bytes(16)
         . pack_namelist('curve25519-sha256')
         . pack_namelist('ssh-ed25519')
         . pack_namelist('chacha20-poly1305@openssh.com')
         . pack_namelist('chacha20-poly1305@openssh.com')
         . pack_namelist('hmac-sha2-256')
         . pack_namelist('hmac-sha2-256')
         . pack_namelist('zlib@openssh.com')
         . pack_namelist('zlib@openssh.com')
         . pack_namelist()
         . pack_namelist()
         . pack_bool(0)
         . pack_u32(0);
}

sub new {
    my ($class, $host, $port, $id, $is_canary) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );
    if (!$sock) {
        return (undef, "TCP connect failed for client #$id: $!");
    }
    binmode($sock);
    my $fl = fcntl($sock, F_GETFL, 0);
    fcntl($sock, F_SETFL, $fl | O_NONBLOCK) if defined $fl;

    my $self = bless {
        id             => $id,
        is_canary      => $is_canary ? 1 : 0,
        sock           => $sock,
        started_at     => clock_gettime(CLOCK_MONOTONIC),
        state          => 'BANNER',
        tx_buf         => "$CLIENT_VERSION\r\n",
        rx_buf         => '',
        tx_seq         => 0,
        rx_seq         => 0,
        tx_enc         => 0,
        rx_enc         => 0,
        tx_k1          => undef,
        tx_k2          => undef,
        rx_k1          => undef,
        rx_k2          => undef,
        comp_active    => 0,
        tx_zlib        => undef,
        rx_zlib        => undef,
        pending_rx_len => undef,
        srv_ver        => undef,
        I_C            => undef,
        I_S            => undef,
        cli_sk         => undef,
        cli_pk         => undef,
        session_id     => undef,
        remote_chan    => undef,
        got_tui        => 0,
        tui_bytes      => 0,
        error          => undef,
    }, $class;

    my $I_C = _build_client_kexinit();
    $self->{I_C} = $I_C;
    $self->queue_packet($I_C);

    return ($self, undef);
}

sub queue_packet {
    my ($self, $payload) = @_;
    my $body = ($self->{comp_active} && $self->{tx_zlib})
        ? $self->{tx_zlib}->deflate($payload)
        : $payload;
    my $blen = length($body);
    my $pad_len;
    if ($self->{tx_enc}) {
        $pad_len = 8 - ((1 + $blen) % 8);
        $pad_len += 8 if $pad_len < 4;
    } else {
        $pad_len = 8 - ((4 + 1 + $blen) % 8);
        $pad_len += 8 if $pad_len < 4;
    }
    my $inner = pack('C', $pad_len) . $body . ("\0" x $pad_len);
    my $wire;
    if ($self->{tx_enc}) {
        $wire = chacha20_poly1305_openssh_encrypt($self->{tx_k1}, $self->{tx_k2}, $self->{tx_seq}, $inner);
    } else {
        $wire = pack('N', length($inner)) . $inner;
    }
    $self->{tx_seq} = ($self->{tx_seq} + 1) & 0xffffffff;
    $self->{tx_buf} .= $wire;
}

sub flush_tx {
    my ($self) = @_;
    while (length($self->{tx_buf}) > 0) {
        my $n = syswrite($self->{sock}, $self->{tx_buf});
        if (defined $n) {
            if ($n == 0) {
                $self->{error} = 'EOF on write';
                return 0;
            }
            substr($self->{tx_buf}, 0, $n, '');
        } elsif ($! == EINTR) {
            next;
        } elsif ($! == EAGAIN || $! == EWOULDBLOCK) {
            last;
        } else {
            $self->{error} = "write error: $!";
            return 0;
        }
    }
    return 1;
}

sub read_rx {
    my ($self) = @_;
    for (1 .. 4) {
        my $buf = '';
        my $n = sysread($self->{sock}, $buf, 16384);
        if (defined $n) {
            if ($n == 0) {
                $self->{error} = 'EOF on read';
                return 0;
            }
            $self->{rx_buf} .= $buf;
            last if $n < 16384;
        } elsif ($! == EINTR) {
            next;
        } elsif ($! == EAGAIN || $! == EWOULDBLOCK) {
            last;
        } else {
            $self->{error} = "read error: $!";
            return 0;
        }
    }
    return 1;
}

sub _pop_packet {
    my ($self) = @_;
    if ($self->{rx_enc}) {
        return undef if length($self->{rx_buf}) < 4;
        if (!defined $self->{pending_rx_len}) {
            my $len4 = substr($self->{rx_buf}, 0, 4);
            $self->{pending_rx_len} = chacha20_poly1305_openssh_decrypt_len($self->{rx_k2}, $self->{rx_seq}, $len4);
        }
        my $plen = $self->{pending_rx_len};
        my $need = 4 + $plen + 16;
        return undef if length($self->{rx_buf}) < $need;
        my $hdr4 = substr($self->{rx_buf}, 0, 4);
        my $body = substr($self->{rx_buf}, 4, $plen);
        my $tag  = substr($self->{rx_buf}, 4 + $plen, 16);
        substr($self->{rx_buf}, 0, $need, '');
        $self->{pending_rx_len} = undef;

        my $inner = chacha20_poly1305_openssh_decrypt_body($self->{rx_k1}, $self->{rx_seq}, $hdr4, $body, $tag);
        if (!defined $inner) {
            $self->{error} = 'Poly1305 MAC verify failed';
            return undef;
        }
        $self->{rx_seq} = ($self->{rx_seq} + 1) & 0xffffffff;
        my $pad_len = unpack('C', substr($inner, 0, 1));
        my $payload = substr($inner, 1, length($inner) - 1 - $pad_len);
        if ($self->{comp_active} && $self->{rx_zlib}) {
            $payload = $self->{rx_zlib}->inflate($payload);
        }
        return $payload;
    } else {
        return undef if length($self->{rx_buf}) < 4;
        my $plen = unpack('N', substr($self->{rx_buf}, 0, 4));
        return undef if length($self->{rx_buf}) < 4 + $plen;
        my $inner = substr($self->{rx_buf}, 4, $plen);
        substr($self->{rx_buf}, 0, 4 + $plen, '');
        $self->{rx_seq} = ($self->{rx_seq} + 1) & 0xffffffff;
        my $pad_len = unpack('C', substr($inner, 0, 1));
        return substr($inner, 1, $plen - 1 - $pad_len);
    }
}

sub step {
    my ($self) = @_;
    return if $self->{error} || $self->{got_tui};

    if ($self->{state} eq 'BANNER') {
        if ((my $idx = index($self->{rx_buf}, "\n")) >= 0) {
            my $line = substr($self->{rx_buf}, 0, $idx + 1, '');
            $line =~ s/\r?\n\z//;
            if ($line =~ /^SSH-2\.0-/) {
                $self->{srv_ver} = $line;
                $self->{state}   = 'KEXINIT';
            }
        } else {
            return;
        }
    }

    while (!$self->{error} && !$self->{got_tui}) {
        my $pkt = $self->_pop_packet();
        last unless defined $pkt;
        my $off = 0;
        my $mtype = unpack_byte($pkt, \$off);

        next if $mtype == SSH_MSG_IGNORE || $mtype == SSH_MSG_DEBUG;

        if ($self->{state} eq 'KEXINIT') {
            if ($mtype != SSH_MSG_KEXINIT) {
                $self->{error} = "Expected KEXINIT, got $mtype";
                return;
            }
            $self->{I_S} = $pkt;
            my ($sk, $pk) = x25519_keypair();
            $self->{cli_sk} = $sk;
            $self->{cli_pk} = $pk;
            $self->queue_packet(pack_byte(SSH_MSG_KEX_ECDH_INIT) . pack_string($pk));
            $self->{state} = 'KEX_REPLY';
        } elsif ($self->{state} eq 'KEX_REPLY') {
            if ($mtype != SSH_MSG_KEX_ECDH_REPLY) {
                $self->{error} = "Expected KEX_ECDH_REPLY, got $mtype";
                return;
            }
            my $K_S      = unpack_string($pkt, \$off);
            my $Q_S      = unpack_string($pkt, \$off);
            my $sig_blob = unpack_string($pkt, \$off);

            my $K_raw = x25519_shared($self->{cli_sk}, $Q_S);
            if (!defined $K_raw) {
                $self->{error} = 'Invalid X25519 shared secret';
                return;
            }
            my $K_encoded = pack_mpint($K_raw);
            my $H = sha256(
                pack_string($CLIENT_VERSION)
                . pack_string($self->{srv_ver})
                . pack_string($self->{I_C})
                . pack_string($self->{I_S})
                . pack_string($K_S)
                . pack_string($self->{cli_pk})
                . pack_string($Q_S)
                . $K_encoded
            );
            $self->{session_id} = $H;

            my $pk_raw = parse_ed25519_pubkey_blob($K_S);
            my $soff   = 0;
            my $salg   = unpack_string($sig_blob, \$soff);
            my $sraw   = unpack_string($sig_blob, \$soff);
            if (!defined($pk_raw) || $salg ne 'ssh-ed25519' || !ed25519_verify($H, $sraw, $pk_raw)) {
                $self->{error} = 'Hostkey ed25519 signature verification failed';
                return;
            }

            my $key_c2s = _derive_key($K_encoded, $H, 'C', $H, 64);
            my $key_s2c = _derive_key($K_encoded, $H, 'D', $H, 64);
            $self->{tx_k1} = substr($key_c2s, 0, 32);
            $self->{tx_k2} = substr($key_c2s, 32, 32);
            $self->{rx_k1} = substr($key_s2c, 0, 32);
            $self->{rx_k2} = substr($key_s2c, 32, 32);

            $self->queue_packet(pack_byte(SSH_MSG_NEWKEYS));
            $self->{tx_enc} = 1;
            $self->queue_packet(pack_byte(SSH_MSG_SERVICE_REQUEST) . pack_string('ssh-userauth'));
            $self->{state} = 'NEWKEYS';
        } elsif ($self->{state} eq 'NEWKEYS') {
            if ($mtype != SSH_MSG_NEWKEYS) {
                $self->{error} = "Expected NEWKEYS, got $mtype";
                return;
            }
            $self->{rx_enc} = 1;
            $self->{state}  = 'SERVICE_ACCEPT';
        } elsif ($self->{state} eq 'SERVICE_ACCEPT') {
            if ($mtype != SSH_MSG_SERVICE_ACCEPT) {
                $self->{error} = "Expected SERVICE_ACCEPT, got $mtype";
                return;
            }
            my $user = "ceil-$self->{id}";
            $self->queue_packet(
                pack_byte(SSH_MSG_USERAUTH_REQUEST)
                . pack_string($user)
                . pack_string('ssh-connection')
                . pack_string('keyboard-interactive')
                . pack_string('')
                . pack_string('')
            );
            $self->{state} = 'USERAUTH';
        } elsif ($self->{state} eq 'USERAUTH') {
            if ($mtype != SSH_MSG_USERAUTH_SUCCESS) {
                $self->{error} = "Expected USERAUTH_SUCCESS, got $mtype";
                return;
            }
            $self->{tx_zlib}     = Shop::SSH::Crypto::Zlib->new(5);
            $self->{rx_zlib}     = Shop::SSH::Crypto::Zlib->new(5);
            $self->{comp_active} = 1;
            $self->queue_packet(
                pack_byte(SSH_MSG_CHANNEL_OPEN)
                . pack_string('session')
                . pack_u32(0)
                . pack_u32(2 * 1024 * 1024)
                . pack_u32(32768)
            );
            $self->{state} = 'CHANNEL_OPEN';
        } elsif ($self->{state} eq 'CHANNEL_OPEN') {
            if ($mtype != SSH_MSG_CHANNEL_OPEN_CONFIRMATION) {
                $self->{error} = "Expected CHANNEL_OPEN_CONFIRMATION, got $mtype";
                return;
            }
            my $recipient = unpack_u32($pkt, \$off);
            my $sender    = unpack_u32($pkt, \$off);
            $self->{remote_chan} = $sender;

            $self->queue_packet(
                pack_byte(SSH_MSG_CHANNEL_REQUEST)
                . pack_u32($sender)
                . pack_string('pty-req')
                . pack_bool(1)
                . pack_string('xterm-256color')
                . pack_u32(80)
                . pack_u32(24)
                . pack_u32(0)
                . pack_u32(0)
                . pack_string('')
            );
            $self->queue_packet(
                pack_byte(SSH_MSG_CHANNEL_REQUEST)
                . pack_u32($sender)
                . pack_string('shell')
                . pack_bool(1)
            );
            $self->{state} = 'WAIT_TUI';
        } elsif ($self->{state} eq 'WAIT_TUI') {
            if ($mtype == SSH_MSG_CHANNEL_DATA) {
                my $rchan = unpack_u32($pkt, \$off);
                my $data  = unpack_string($pkt, \$off);
                $self->{tui_bytes} += length($data);
                if ($data =~ /\e\[/) {
                    $self->{got_tui} = 1;
                    $self->{state}   = 'ESTABLISHED';
                    if (!$self->{is_canary}) {
                        $self->{tx_zlib} = undef;
                        $self->{rx_zlib} = undef;
                        $self->{rx_buf}  = '';
                    }
                    return;
                }
            }
        }
    }
}

sub drain_inbound {
    my ($self) = @_;
    return if $self->{error};
    $self->read_rx();
    while (!$self->{error} && defined(my $pkt = $self->_pop_packet())) {
        # discard any pending initial render or window-adjust packets
    }
}

sub probe_keypress_rtt_ms {
    my ($self, $key, $timeout_sec) = @_;
    $timeout_sec //= 5.0;
    return (undef, $self->{error}) if $self->{error};

    $self->drain_inbound();
    return (undef, $self->{error}) if $self->{error};

    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    $self->queue_packet(
        pack_byte(SSH_MSG_CHANNEL_DATA)
        . pack_u32($self->{remote_chan})
        . pack_string($key)
    );
    while (length($self->{tx_buf}) > 0) {
        return (undef, $self->{error}) unless $self->flush_tx();
        if (length($self->{tx_buf}) > 0) {
            my $wp = IO::Poll->new();
            $wp->mask($self->{sock} => POLLOUT);
            $wp->poll(0.05);
        }
    }

    my $deadline = $t0 + $timeout_sec;
    my $rp = IO::Poll->new();
    $rp->mask($self->{sock} => POLLIN);

    while (1) {
        my $now = clock_gettime(CLOCK_MONOTONIC);
        my $rem = $deadline - $now;
        return (undef, "keypress RTT timeout after ${timeout_sec}s") if $rem <= 0;

        my $rc = $rp->poll($rem);
        if ($rc > 0) {
            if (!$self->read_rx()) {
                return (undef, $self->{error} // 'EOF during keypress probe');
            }
            while (defined(my $pkt = $self->_pop_packet())) {
                my $off = 0;
                my $mtype = unpack_byte($pkt, \$off);
                if ($mtype == SSH_MSG_CHANNEL_DATA) {
                    my $rchan = unpack_u32($pkt, \$off);
                    my $data  = unpack_string($pkt, \$off);
                    my $rtt_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;
                    return ($rtt_ms, undef, length($data));
                }
            }
            return (undef, $self->{error}) if $self->{error};
        }
    }
}

package main;

# ---------------------------------------------------------------------------
# Ramp SSHv2 sessions across milestones and measure ceiling / knee of curve
# ---------------------------------------------------------------------------
my @open_sockets;
my @canaries;
my @milestone_rows;
my $total_opened     = 0;
my $total_errors     = 0;
my $next_id          = 1;
my $total_hs_sec     = 0.0;
my $ceiling_hit      = 0;
my $ceiling_reason   = 'none';
my $ceiling_sessions = 0;
my $last_error_msg   = '';
my $hs_timeout_sec   = 20.0;
my $server_dead      = 0;
my $server_exit_desc = '';
my $server_log_tail  = '';

sub check_server_alive {
    return 0 if $server_dead || !defined($server_pid);
    my $r = waitpid($server_pid, POSIX::WNOHANG());
    if ($r == $server_pid || $r < 0) {
        my $st  = $?;
        my $sig = $st & 127;
        my $rc  = $st >> 8;
        $server_dead      = 1;
        $server_pid       = undef;
        $server_exit_desc = $sig ? "terminated by signal $sig" : "exited with code $rc";
        if (open my $lf, '<', $srv_log) {
            my @lines = <$lf>;
            close $lf;
            my $start = @lines > 25 ? $#lines - 24 : 0;
            $server_log_tail = join('', @lines[$start .. $#lines]);
        }
        return 0;
    }
    return 1;
}

print "====================================================================================================================\n";
printf " 07_concurrency_ceiling: Real SSHv2 Ceiling Ramp (max=%d, workers=%d, stack=%d, conc=%d, canaries=%d)\n",
    $max_sessions, $session_workers, $fiber_stack, $concurrency, $num_canaries;
printf " Cipher: chacha20-poly1305\@openssh.com | KEX: curve25519-sha256 | Comp: zlib\@openssh.com | RTT limit: %.0f ms\n",
    $rtt_limit_ms;
printf " Baseline RSS: %.2f MiB (%d KB) | Server PID: %d | Milestones: %s\n",
    $baseline_rss_kb / 1024, $baseline_rss_kb, $server_pid, join(', ', @milestones);
print "====================================================================================================================\n";
printf "%8s %9s %8s %8s %8s %7s %9s %9s %9s %7s %6s\n",
    'Sessions', 'RSS(MiB)', 'KB/fib', 'HS/sec', 'CPU%1s', 'ps%CPU', 'RTTp50', 'RTTp95', 'RTTmax', 'Parity', 'Errs';
printf "%8s %9s %8s %8s %8s %7s %9s %9s %9s %7s %6s\n",
    '-' x 8, '-' x 9, '-' x 8, '-' x 8, '-' x 8, '-' x 7, '-' x 9, '-' x 9, '-' x 9, '-' x 7, '-' x 6;

my $milestone_idx = 0;
for my $target (@milestones) {
    my $need    = $target - $total_opened;
    my $t_batch = clock_gettime(CLOCK_MONOTONIC);

    my %in_flight; # fileno -> CeilingSSHClient
    my $poll             = IO::Poll->new();
    my $spawned_in_batch = 0;
    my $done_in_batch    = 0;
    my $batch_errors     = 0;
    my $stop_spawning    = 0;

    while (($done_in_batch < $need && !$stop_spawning) || scalar(keys %in_flight) > 0) {
        while (!$stop_spawning
            && scalar(keys %in_flight) < $concurrency
            && $spawned_in_batch < $need)
        {
            my $id        = $next_id++;
            my $is_canary = (scalar(@canaries) < $num_canaries && $id <= $num_canaries) ? 1 : 0;
            my ($cli, $err) = CeilingSSHClient->new('127.0.0.1', $ssh_port, $id, $is_canary);
            if (!$cli) {
                $batch_errors++;
                $total_errors++;
                $last_error_msg = $err;
                $stop_spawning  = 1;
                last;
            }
            my $fd = fileno($cli->{sock});
            $in_flight{$fd} = $cli;
            $poll->mask($cli->{sock} => POLLIN | POLLOUT);
            $spawned_in_batch++;
        }

        last unless scalar(keys %in_flight) > 0;

        my $nready = $poll->poll(0.05);
        if ($nready > 0) {
            for my $s ($poll->handles(POLLOUT)) {
                my $fd  = fileno($s);
                my $cli = $in_flight{$fd} or next;
                $cli->flush_tx();
                if (!$cli->{error} && length($cli->{tx_buf}) == 0) {
                    $poll->mask($s => POLLIN);
                }
            }
            for my $s ($poll->handles(POLLIN | POLLERR | POLLHUP)) {
                my $fd  = fileno($s);
                my $cli = $in_flight{$fd} or next;
                $cli->read_rx();
                $cli->step();
                if (!$cli->{error} && length($cli->{tx_buf}) > 0) {
                    $cli->flush_tx();
                    $poll->mask($s => (length($cli->{tx_buf}) > 0 ? (POLLIN | POLLOUT) : POLLIN));
                }
            }
        }

        my $now = clock_gettime(CLOCK_MONOTONIC);
        for my $fd (keys %in_flight) {
            my $cli = $in_flight{$fd};
            if ($cli->{got_tui}) {
                $poll->remove($cli->{sock});
                delete $in_flight{$fd};
                if ($cli->{is_canary}) {
                    push @canaries, $cli;
                } else {
                    push @open_sockets, $cli->{sock};
                }
                $done_in_batch++;
                $total_opened++;
            } elsif ($cli->{error}) {
                $poll->remove($cli->{sock});
                close($cli->{sock});
                delete $in_flight{$fd};
                $batch_errors++;
                $total_errors++;
                $last_error_msg = "client #$cli->{id} at $cli->{state}: $cli->{error}";
                $stop_spawning  = 1;
            } elsif (($now - $cli->{started_at}) > $hs_timeout_sec) {
                $poll->remove($cli->{sock});
                close($cli->{sock});
                delete $in_flight{$fd};
                $batch_errors++;
                $total_errors++;
                $last_error_msg = "client #$cli->{id} handshake timeout at $cli->{state} (>${hs_timeout_sec}s)";
                $stop_spawning  = 1;
            }
        }
    }

    my $batch_sec = clock_gettime(CLOCK_MONOTONIC) - $t_batch;
    $batch_sec = 1e-6 if $batch_sec <= 0;
    $total_hs_sec += $batch_sec;
    my $hs_per_sec = $done_in_batch / $batch_sec;

    # 1.0s settle at milestone (skip if server already exited)
    usleep(1_000_000) if check_server_alive();
    my $srv_alive = check_server_alive();

    # 1. RSS & KB/fiber
    my $rss_kb     = $srv_alive ? measure_rss_kb($server_pid) : 0;
    my $rss_mb     = $rss_kb / 1024.0;
    my $delta_kb   = $srv_alive ? ($rss_kb - $baseline_rss_kb) : 0;
    my $delta_mb   = $delta_kb / 1024.0;
    my $kb_per_fib = ($srv_alive && $total_opened > 0) ? ($delta_kb / $total_opened) : 0.0;

    # 2. Steady-state server idle CPU% over a 1.0s window
    my ($ps_pcpu, $inst_cpu_pct) = (0.0, 0.0);
    if ($srv_alive) {
        my $cpu0 = measure_cpu_time_sec($server_pid);
        my $w0   = clock_gettime(CLOCK_MONOTONIC);
        usleep(1_000_000);
        if (check_server_alive()) {
            my $cpu1 = measure_cpu_time_sec($server_pid);
            my $w1   = clock_gettime(CLOCK_MONOTONIC);
            $ps_pcpu = measure_ps_pcpu($server_pid);
            $inst_cpu_pct = (defined($cpu0) && defined($cpu1) && $w1 > $w0)
                ? (($cpu1 - $cpu0) / ($w1 - $w0) * 100.0)
                : 0.0;
            $inst_cpu_pct = 0.0 if $inst_cpu_pct < 0;
        } else {
            $srv_alive = 0;
        }
    }

    # 3. Live interactive keypress RTT across canary sessions
    my $probe_key = ($milestone_idx < 10 || ($milestone_idx % 2 == 0)) ? 'j' : 'k';
    my @rtt_samples;
    my $canary_errors = 0;
    if ($srv_alive) {
        for my $c (@canaries) {
            my ($rtt_ms, $err, $bytes) = $c->probe_keypress_rtt_ms($probe_key, 5.0);
            if (defined $rtt_ms) {
                push @rtt_samples, $rtt_ms;
            } else {
                $canary_errors++;
                $batch_errors++;
                $total_errors++;
                $last_error_msg = "canary #$c->{id} keypress probe failed: " . ($err // 'unknown');
            }
        }
    }
    my $rtt_p50 = percentile(\@rtt_samples, 50);
    my $rtt_p95 = percentile(\@rtt_samples, 95);
    my $rtt_max = @rtt_samples ? (sort { $a <=> $b } @rtt_samples)[-1] : 0.0;

    # 4. /metrics parity
    my $metrics        = $srv_alive ? fetch_metrics('127.0.0.1', $ops_port) : {};
    my $active_metrics = int($metrics->{ssh_active_sessions} // -1);
    my $parity         = ($srv_alive && $active_metrics == $total_opened) ? 1 : 0;

    check_server_alive();
    if ($server_dead) {
        $batch_errors++ if $batch_errors == 0;
        $total_errors++ if $total_errors == 0;
        $last_error_msg = "shop-server $server_exit_desc";
    }

    printf "%8d %9.2f %8.2f %8.1f %7.1f%% %6.1f%% %7.2fms %7.2fms %7.2fms %7s %6d\n",
        $total_opened, $rss_mb, $kb_per_fib, $hs_per_sec,
        $inst_cpu_pct, $ps_pcpu,
        $rtt_p50, $rtt_p95, $rtt_max,
        ($parity ? 'OK' : "M($active_metrics)"),
        $batch_errors;

    push @milestone_rows, {
        target_sessions    => int($target),
        sessions           => int($total_opened),
        rss_kb             => int($rss_kb),
        rss_mb             => sprintf('%.2f', $rss_mb) + 0,
        delta_mb           => sprintf('%.2f', $delta_mb) + 0,
        kb_per_fiber       => sprintf('%.2f', $kb_per_fib) + 0,
        batch_elapsed_sec  => sprintf('%.3f', $batch_sec) + 0,
        handshakes_per_sec => sprintf('%.1f', $hs_per_sec) + 0,
        idle_cpu_pct_1s    => sprintf('%.1f', $inst_cpu_pct) + 0,
        ps_pcpu_decayed    => sprintf('%.1f', $ps_pcpu) + 0,
        keypress_rtt_ms    => {
            key      => $probe_key,
            canaries => int(scalar @rtt_samples),
            p50      => sprintf('%.2f', $rtt_p50) + 0,
            p95      => sprintf('%.2f', $rtt_p95) + 0,
            max      => sprintf('%.2f', $rtt_max) + 0,
        },
        metrics_active     => int($active_metrics),
        metrics_parity     => $parity ? JSON::PP::true : JSON::PP::false,
        errors             => int($batch_errors),
    };

    $ceiling_sessions = $total_opened;
    $milestone_idx++;

    # 5. Stop cleanly if errors > 0 or p95 keypress RTT > limit
    if ($total_errors > 0) {
        $ceiling_hit    = 1;
        $ceiling_reason = "errors ($total_errors): $last_error_msg";
        last;
    }
    if (@rtt_samples && $rtt_p95 > $rtt_limit_ms) {
        $ceiling_hit    = 1;
        $ceiling_reason = sprintf('p95 keypress RTT %.2f ms exceeded %.0f ms threshold', $rtt_p95, $rtt_limit_ms);
        last;
    }
}

my $overall_hs_per_sec = $total_hs_sec > 0 ? ($total_opened / $total_hs_sec) : 0;

# Disconnect all sessions cleanly and measure drain time
my $drain_start = clock_gettime(CLOCK_MONOTONIC);
for my $c (@canaries) {
    close($c->{sock}) if $c->{sock};
}
@canaries = ();
for my $s (@open_sockets) {
    close($s);
}
@open_sockets = ();

my $post_active = -1;
my $drain_sec   = 0.0;
if (check_server_alive()) {
    for (1 .. 300) {
        last unless check_server_alive();
        my $m = fetch_metrics('127.0.0.1', $ops_port);
        $post_active = int($m->{ssh_active_sessions} // -1);
        last if $post_active == 0;
        usleep(100_000);
    }
    $drain_sec = clock_gettime(CLOCK_MONOTONIC) - $drain_start;
    usleep(300_000);
}

my $post_drain_rss_kb = check_server_alive() ? measure_rss_kb($server_pid) : 0;
my $post_drain_rss_mb = $post_drain_rss_kb / 1024.0;
my $final_metrics     = check_server_alive() ? fetch_metrics('127.0.0.1', $ops_port) : {};

# Measure clean SIGTERM shutdown time (ms)
my $shutdown_ms    = 0.0;
my $clean_shutdown = 0;
if (check_server_alive()) {
    my $t_term = clock_gettime(CLOCK_MONOTONIC);
    kill 'TERM', $server_pid;
    for (1 .. 2000) {
        my $r = waitpid($server_pid, POSIX::WNOHANG());
        if ($r == $server_pid || $r < 0) {
            $server_pid     = undef;
            $clean_shutdown = 1;
            last;
        }
        usleep(5_000);
    }
    $shutdown_ms = (clock_gettime(CLOCK_MONOTONIC) - $t_term) * 1000.0;
}

print "--------------------------------------------------------------------------------------------------------------------\n";
printf " Peak live sessions     : %d (ceiling_hit=%s, reason=%s)\n",
    $ceiling_sessions, ($ceiling_hit ? 'yes' : 'no'), $ceiling_reason;
printf " Overall handshakes/sec : %.1f (%d sessions in %.2fs, errors=%d)\n",
    $overall_hs_per_sec, $total_opened, $total_hs_sec, $total_errors;
printf " Post-drain active      : %d (drained in %.2fs)\n", $post_active, $drain_sec;
printf " Post-drain RSS         : %.2f MiB (%d KB) vs Baseline %.2f MiB\n",
    $post_drain_rss_mb, $post_drain_rss_kb, $baseline_rss_kb / 1024.0;
printf " Clean SIGTERM shutdown : %.1f ms (%s)\n",
    $shutdown_ms, ($clean_shutdown ? 'clean' : ($server_dead ? "server_died: $server_exit_desc" : 'timeout'));
if ($server_dead && length $server_log_tail) {
    print " --- shop-server log tail ---\n";
    print $server_log_tail;
    print "\n" unless $server_log_tail =~ /\n\z/;
}
print "====================================================================================================================\n";

my $result = {
    benchmark            => '07_concurrency_ceiling',
    mode                 => $smoke ? 'smoke' : 'full',
    config => {
        max_sessions    => int($max_sessions),
        concurrency     => int($concurrency),
        session_workers => int($session_workers),
        mt_fiber_stack  => int($fiber_stack),
        canaries        => int($num_canaries),
        rtt_limit_ms    => $rtt_limit_ms + 0,
        kex             => 'curve25519-sha256',
        cipher          => 'chacha20-poly1305@openssh.com',
        compression     => 'zlib@openssh.com',
        db_driver       => 'sqlite',
    },
    baseline_rss_kb      => int($baseline_rss_kb),
    baseline_rss_mb      => sprintf('%.2f', $baseline_rss_kb / 1024.0) + 0,
    peak_sessions        => int($ceiling_sessions),
    ceiling_hit          => $ceiling_hit ? JSON::PP::true : JSON::PP::false,
    ceiling_reason       => $ceiling_reason,
    overall_elapsed_sec  => sprintf('%.3f', $total_hs_sec) + 0,
    overall_hs_per_sec   => sprintf('%.1f', $overall_hs_per_sec) + 0,
    milestones           => \@milestone_rows,
    post_drain => {
        active_sessions   => int($post_active),
        drain_sec         => sprintf('%.3f', $drain_sec) + 0,
        rss_kb            => int($post_drain_rss_kb),
        rss_mb            => sprintf('%.2f', $post_drain_rss_mb) + 0,
        connections_total => int($final_metrics->{ssh_connections_total} // 0),
        shutdown_ms       => sprintf('%.1f', $shutdown_ms) + 0,
        clean_shutdown    => $clean_shutdown ? JSON::PP::true : JSON::PP::false,
    },
    errors => int($total_errors),
};

if (length $json_path) {
    make_path(dirname($json_path));
    my $tmp = "$json_path.tmp.$$";
    open my $fh, '>', $tmp or die "Cannot open $tmp: $!\n";
    print $fh JSON::PP->new->utf8->pretty->canonical->encode($result);
    close $fh or die "Cannot close $tmp: $!\n";
    rename $tmp, $json_path or die "Cannot rename $tmp -> $json_path: $!\n";
    print "Wrote JSON results to $json_path\n";
}

exit 0;
