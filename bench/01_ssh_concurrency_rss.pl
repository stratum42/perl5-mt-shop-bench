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
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR EINPROGRESS);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC usleep);

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

my $max_sessions    = 1000;
my $concurrency     = 16;
my $session_workers = 4;
my $fiber_stack     = 32768;
my $smoke           = 0;
my $json_path       = '';

GetOptions(
    'max=i'             => \$max_sessions,
    'concurrency=i'     => \$concurrency,
    'session-workers=i' => \$session_workers,
    'fiber-stack=i'     => \$fiber_stack,
    'smoke!'            => \$smoke,
    'json=s'            => \$json_path,
) or die "Usage: $0 [--max N] [--concurrency N] [--session-workers N] [--fiber-stack bytes] [--smoke] [--json path]\n";

if ($smoke && $max_sessions == 1000) {
    $max_sessions = 100;
}
$max_sessions    = 1   if $max_sessions < 1;
$concurrency     = 1   if $concurrency < 1;
$concurrency     = $max_sessions if $concurrency > $max_sessions;

# Build milestone schedule
my @milestones;
if ($smoke && $max_sessions == 100) {
    @milestones = (25, 50, 100);
} else {
    my @std = (100, 250, 500, 750, 1000);
    @milestones = grep { $_ <= $max_sessions } @std;
    push @milestones, $max_sessions if !@milestones || $milestones[-1] != $max_sessions;
}

# ---------------------------------------------------------------------------
# Helpers: ephemeral ports, RSS measurement, HTTP /healthz & /metrics
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

sub http_get {
    my ($host, $port, $path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 3,
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
my $tmp_dir    = tempdir(CLEANUP => 1);
my $ssh_port   = pick_ephemeral_port();
my $ops_port   = pick_ephemeral_port();
my $cfg_path   = "$tmp_dir/shop_bench.json";
my $db_path    = "$tmp_dir/shop_bench.sqlite";
my $ckpt_path  = "$tmp_dir/inventory.mtck";
my $hostkey_p  = "$SHOP_ROOT/config/host_ed25519_key";
$hostkey_p     = "$tmp_dir/host_ed25519_key" unless -f $hostkey_p;
my $srv_log    = "$tmp_dir/shop_server.log";

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
        port   => 1, # unreachable on purpose so benchmark stays isolated on sqlite
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

require POSIX;

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
for (1 .. 100) {
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
usleep(200_000); # let startup settle

my $baseline_rss_kb = measure_rss_kb($server_pid);

# ---------------------------------------------------------------------------
# Minimal real SSHv2 client (curve25519-sha256 + chacha20-poly1305 + zlib)
# ---------------------------------------------------------------------------
package BenchSSHClient;
use strict;
use warnings;
use IO::Socket::INET;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
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

my $CLIENT_VERSION = 'SSH-2.0-perl5-mt-shop-bench';

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
    my ($class, $host, $port, $id) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "TCP connect failed for client #$id: $!\n";
    binmode($sock);
    my $fl = fcntl($sock, F_GETFL, 0);
    fcntl($sock, F_SETFL, $fl | O_NONBLOCK) if defined $fl;

    my $self = bless {
        id             => $id,
        sock           => $sock,
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

    # Queue KEXINIT right after banner
    my $I_C = _build_client_kexinit();
    $self->{I_C} = $I_C;
    $self->queue_packet($I_C);

    return $self;
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
                $self->{error} = 'EOF on read' unless $self->{got_tui};
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

        # Skip debug/ignore
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

            # Verify server ed25519 hostkey signature
            my $pk_raw = parse_ed25519_pubkey_blob($K_S);
            my $soff = 0;
            my $salg = unpack_string($sig_blob, \$soff);
            my $sraw = unpack_string($sig_blob, \$soff);
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

            # Send client NEWKEYS and activate tx encryption
            $self->queue_packet(pack_byte(SSH_MSG_NEWKEYS));
            $self->{tx_enc} = 1;
            # Queue SERVICE_REQUEST("ssh-userauth")
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
            my $user = "bench-$self->{id}";
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
                    # Release zlib state on client side to keep client memory tiny
                    $self->{tx_zlib} = undef;
                    $self->{rx_zlib} = undef;
                    $self->{rx_buf}  = '';
                    return;
                }
            }
        }
    }
}

package main;

# ---------------------------------------------------------------------------
# Drive concurrent SSH sessions across milestones
# ---------------------------------------------------------------------------
my @open_sockets;
my @milestone_rows;
my $total_opened  = 0;
my $total_errors  = 0;
my $next_id       = 1;
my $total_hs_sec  = 0.0;

print "==========================================================================================\n";
printf " 01_ssh_concurrency_rss: Real SSHv2 Sessions (max=%d, MT_FIBER_STACK=%d, workers=%d)\n",
    $max_sessions, $fiber_stack, $session_workers;
printf " Cipher: chacha20-poly1305\@openssh.com | KEX: curve25519-sha256 | Comp: zlib\@openssh.com\n";
printf " Baseline RSS: %.2f MB (%d KB) | Server PID: %d\n",
    $baseline_rss_kb / 1024, $baseline_rss_kb, $server_pid;
print "==========================================================================================\n";
printf "%8s %10s %10s %10s %10s %10s %10s\n",
    'Sessions', 'RSS (MB)', 'Delta MB', 'KB/fiber', 'HS/sec', '/metrics', 'Parity';
printf "%8s %10s %10s %10s %10s %10s %10s\n",
    '-' x 8, '-' x 10, '-' x 10, '-' x 10, '-' x 10, '-' x 10, '-' x 10;

for my $target (@milestones) {
    my $need    = $target - $total_opened;
    my $t_batch = clock_gettime(CLOCK_MONOTONIC);

    my %in_flight; # fileno -> BenchSSHClient
    my $r_sel = IO::Select->new();
    my $w_sel = IO::Select->new();
    my $spawned_in_batch = 0;
    my $done_in_batch    = 0;

    while ($done_in_batch < $need) {
        while (scalar(keys %in_flight) < $concurrency && $spawned_in_batch < $need) {
            my $cli = BenchSSHClient->new('127.0.0.1', $ssh_port, $next_id++);
            my $fd  = fileno($cli->{sock});
            $in_flight{$fd} = $cli;
            $r_sel->add($cli->{sock});
            $w_sel->add($cli->{sock});
            $spawned_in_batch++;
        }

        my ($r_ready, $w_ready) = IO::Select->select($r_sel, $w_sel, undef, 0.05);

        if ($w_ready) {
            for my $s (@$w_ready) {
                my $fd  = fileno($s);
                my $cli = $in_flight{$fd} or next;
                $cli->flush_tx();
                $w_sel->remove($s) if length($cli->{tx_buf}) == 0;
            }
        }
        if ($r_ready) {
            for my $s (@$r_ready) {
                my $fd  = fileno($s);
                my $cli = $in_flight{$fd} or next;
                $cli->read_rx();
                $cli->step();
                if (length($cli->{tx_buf}) > 0) {
                    $cli->flush_tx();
                    $w_sel->add($s) if length($cli->{tx_buf}) > 0 && !$w_sel->exists($s);
                }
            }
        }

        for my $fd (keys %in_flight) {
            my $cli = $in_flight{$fd};
            if ($cli->{got_tui}) {
                $r_sel->remove($cli->{sock});
                $w_sel->remove($cli->{sock});
                delete $in_flight{$fd};
                push @open_sockets, $cli->{sock};
                $done_in_batch++;
                $total_opened++;
            } elsif ($cli->{error}) {
                $r_sel->remove($cli->{sock});
                $w_sel->remove($cli->{sock});
                close($cli->{sock});
                delete $in_flight{$fd};
                $total_errors++;
                die "SSH client #$cli->{id} failed at state $cli->{state}: $cli->{error}\n";
            }
        }
    }

    my $batch_sec = clock_gettime(CLOCK_MONOTONIC) - $t_batch;
    $batch_sec = 1e-6 if $batch_sec <= 0;
    $total_hs_sec += $batch_sec;
    my $hs_per_sec = $need / $batch_sec;

    # Allow server fibers to finish initial render and settle
    usleep(200_000);

    my $rss_kb     = measure_rss_kb($server_pid);
    my $rss_mb     = $rss_kb / 1024.0;
    my $delta_kb   = $rss_kb - $baseline_rss_kb;
    my $delta_mb   = $delta_kb / 1024.0;
    my $kb_per_fib = $total_opened > 0 ? ($delta_kb / $total_opened) : 0.0;

    my $metrics        = fetch_metrics('127.0.0.1', $ops_port);
    my $active_metrics = int($metrics->{ssh_active_sessions} // -1);
    my $parity         = ($active_metrics == $total_opened) ? 1 : 0;

    printf "%8d %10.2f %10.2f %10.2f %10.1f %10d %10s\n",
        $total_opened, $rss_mb, $delta_mb, $kb_per_fib, $hs_per_sec,
        $active_metrics, ($parity ? 'OK' : 'MISMATCH');

    push @milestone_rows, {
        sessions            => int($total_opened),
        rss_kb              => int($rss_kb),
        rss_mb              => sprintf('%.2f', $rss_mb) + 0,
        delta_mb            => sprintf('%.2f', $delta_mb) + 0,
        kb_per_fiber        => sprintf('%.2f', $kb_per_fib) + 0,
        batch_elapsed_sec   => sprintf('%.3f', $batch_sec) + 0,
        handshakes_per_sec  => sprintf('%.1f', $hs_per_sec) + 0,
        metrics_active      => int($active_metrics),
        metrics_parity      => $parity ? JSON::PP::true : JSON::PP::false,
    };
}

my $overall_hs_per_sec = $total_hs_sec > 0 ? ($total_opened / $total_hs_sec) : 0;

# Drain all sessions cleanly
for my $s (@open_sockets) {
    close($s);
}
@open_sockets = ();

my $drain_start = clock_gettime(CLOCK_MONOTONIC);
my $post_active = -1;
for (1 .. 150) {
    my $m = fetch_metrics('127.0.0.1', $ops_port);
    $post_active = int($m->{ssh_active_sessions} // -1);
    last if $post_active == 0;
    usleep(100_000);
}
my $drain_sec = clock_gettime(CLOCK_MONOTONIC) - $drain_start;
usleep(300_000);

my $post_drain_rss_kb = measure_rss_kb($server_pid);
my $post_drain_rss_mb = $post_drain_rss_kb / 1024.0;
my $final_metrics     = fetch_metrics('127.0.0.1', $ops_port);

print "------------------------------------------------------------------------------------------\n";
printf " Overall handshakes/sec : %.1f (%d sessions in %.2fs)\n",
    $overall_hs_per_sec, $total_opened, $total_hs_sec;
printf " Post-drain active      : %d (drained in %.2fs)\n", $post_active, $drain_sec;
printf " Post-drain RSS         : %.2f MB (%d KB) vs Baseline %.2f MB\n",
    $post_drain_rss_mb, $post_drain_rss_kb, $baseline_rss_kb / 1024.0;
print "==========================================================================================\n";

# Cleanly stop shop-server
kill 'TERM', $server_pid;
for (1 .. 100) {
    my $r = waitpid($server_pid, POSIX::WNOHANG());
    if ($r == $server_pid || $r < 0) {
        $server_pid = undef;
        last;
    }
    usleep(50_000);
}

my $result = {
    benchmark            => '01_ssh_concurrency_rss',
    mode                 => $smoke ? 'smoke' : 'full',
    config => {
        max_sessions    => int($max_sessions),
        concurrency     => int($concurrency),
        session_workers => int($session_workers),
        mt_fiber_stack  => int($fiber_stack),
        kex             => 'curve25519-sha256',
        cipher          => 'chacha20-poly1305@openssh.com',
        compression     => 'zlib@openssh.com',
        db_driver       => 'sqlite',
    },
    baseline_rss_kb      => int($baseline_rss_kb),
    baseline_rss_mb      => sprintf('%.2f', $baseline_rss_kb / 1024.0) + 0,
    overall_elapsed_sec  => sprintf('%.3f', $total_hs_sec) + 0,
    overall_hs_per_sec   => sprintf('%.1f', $overall_hs_per_sec) + 0,
    milestones           => \@milestone_rows,
    post_drain => {
        active_sessions => int($post_active),
        drain_sec       => sprintf('%.3f', $drain_sec) + 0,
        rss_kb          => int($post_drain_rss_kb),
        rss_mb          => sprintf('%.2f', $post_drain_rss_mb) + 0,
        connections_total => int($final_metrics->{ssh_connections_total} // 0),
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
