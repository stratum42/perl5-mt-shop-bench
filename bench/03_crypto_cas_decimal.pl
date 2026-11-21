#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);

BEGIN {
    my $bench_root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
    my $parent     = File::Spec->rel2abs(File::Spec->catdir($bench_root, '..'));
    my $perl_root  = $ENV{PERL5_MT_ROOT}       // File::Spec->catdir($parent, 'perl5-mt');
    my $shop_root  = $ENV{SHOP_ROOT}           // File::Spec->catdir($parent, 'perl5-mt-shop');
    my $mojo_root  = $ENV{MOJOLICIOUS_MT_ROOT} // File::Spec->catdir($parent, 'mojolicious-mt');

    for my $dir (
        "$mojo_root/xs-keydb/blib/arch",
        "$mojo_root/xs-keydb/blib/lib",
        "$mojo_root/xs/blib/arch",
        "$mojo_root/xs/blib/lib",
        "$mojo_root/lib",
        "$shop_root/xs/Shop-SSH-Crypto/blib/arch",
        "$shop_root/xs/Shop-SSH-Crypto/blib/lib",
        "$shop_root/lib",
        "$perl_root/lib",
    ) {
        unshift @INC, $dir if -d $dir && !grep { $_ eq $dir } @INC;
    }
}

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use MT;
use MT::Channel;
use MT::Cell;
use MT::Decimal;

use Shop::SSH::Crypto qw(
    random_bytes
    x25519_keypair
    x25519_shared
    mlkem768_encapsulate
    ed25519_keypair
    ed25519_sign
    ed25519_verify
    chacha20_poly1305_openssh_encrypt
    aes256_gcm_openssh_encrypt
);
use Shop::State::Inventory;
use Shop::Domain::Pricing;
use Shop::TUI::Screen;

my $smoke     = 0;
my $json_path = '';

GetOptions(
    'smoke!' => \$smoke,
    'json=s' => \$json_path,
) or die "Usage: $0 [--smoke] [--json path]\n";

# ---------------------------------------------------------------------------
# Worker entrypoints (defined before MT::Image::freeze)
# ---------------------------------------------------------------------------

sub _make_mlkem768_ek {
    # 768 12-bit coefficients mod 3329 (1152 bytes) + 32-byte rho seed = 1184 bytes
    my $ek = '';
    for (my $i = 0; $i < 384; $i++) {
        my $c0 = ($i * 7 + 13) % 3329;
        my $c1 = ($i * 11 + 29) % 3329;
        $ek .= pack('CCC', $c0 & 0xff, (($c0 >> 8) & 0x0f) | (($c1 & 0x0f) << 4), ($c1 >> 4) & 0xff);
    }
    $ek .= random_bytes(32);
    return $ek;
}

sub w_x25519 {
    my ($iters, $peer_pk) = @_;
    my $done = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my ($sk, $pk) = Shop::SSH::Crypto::x25519_keypair();
        my $sh = Shop::SSH::Crypto::x25519_shared($sk, $peer_pk);
        $done++ if defined $sh;
    }
    return $done;
}

sub w_mlkem768 {
    my ($iters, $ek) = @_;
    my $done = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my ($ct, $ss) = Shop::SSH::Crypto::mlkem768_encapsulate($ek);
        $done++ if defined $ss;
    }
    return $done;
}

sub w_ed25519_sign {
    my ($iters, $sk, $msg) = @_;
    my $done = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my $sig = Shop::SSH::Crypto::ed25519_sign($msg, $sk);
        $done++ if length($sig) == 64;
    }
    return $done;
}

sub w_ed25519_verify {
    my ($iters, $pk, $msg, $sig) = @_;
    my $done = 0;
    for (my $i = 0; $i < $iters; $i++) {
        $done++ if Shop::SSH::Crypto::ed25519_verify($msg, $sig, $pk);
    }
    return $done;
}

sub w_chacha20 {
    my ($iters, $payload_len) = @_;
    my $k1 = Shop::SSH::Crypto::random_bytes(32);
    my $k2 = Shop::SSH::Crypto::random_bytes(32);
    my $payload = ('A' x $payload_len);
    my $bytes = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my $pkt = Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt($k1, $k2, $i, $payload);
        $bytes += $payload_len if length($pkt) > $payload_len;
    }
    return $bytes;
}

sub w_aes256gcm {
    my ($iters, $payload_len) = @_;
    my $key  = Shop::SSH::Crypto::random_bytes(32);
    my $iv   = Shop::SSH::Crypto::random_bytes(12);
    my $payload = ('B' x $payload_len);
    my $aad4 = pack('N', $payload_len);
    my $bytes = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my $pkt = Shop::SSH::Crypto::aes256_gcm_openssh_encrypt($key, $iv, $i, $aad4, $payload);
        $bytes += $payload_len if length($pkt) > $payload_len;
    }
    return $bytes;
}

sub w_zlib_deflate {
    my ($iters, $level) = @_;
    my $z = Shop::SSH::Crypto::Zlib->new($level);
    my $chunk = ("\e[38;5;46m| VT-220 | DEC VT220 Amber Terminal | \$429.00 | STOCK: 12 |\e[0m\r\n") x 64;
    my $clen = length($chunk);
    my $bytes = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my $c = $z->deflate($chunk);
        $bytes += $clen if length($c) > 0;
    }
    return $bytes;
}

sub w_cas_inventory {
    my ($products_id, $cells_id, $pairs, $out_chan_id) = @_;
    my $inv = Shop::State::Inventory->attach({ products_id => $products_id, cells_id => $cells_id });
    my $out = MT::Channel->attach($out_chan_id);
    my $ok_pairs = 0;
    for (my $i = 0; $i < $pairs; $i++) {
        my ($ok) = $inv->reserve('BENCH-CAS-SKU', 1);
        if ($ok) {
            $ok_pairs++;
            $inv->release('BENCH-CAS-SKU', 1);
        }
    }
    $out->send($ok_pairs);
    return $ok_pairs;
}

sub w_decimal_pricing {
    my ($iters) = @_;
    my $items = [
        { sku => 'VT-220', name => 'DEC VT220 Amber Terminal', qty => 2, unit_price => '429.00' },
        { sku => 'KB-M01', name => 'Model M Clicky Keyboard',  qty => 1, unit_price => '149.95' },
        { sku => 'AC-MUG', name => '0xDEADBEEF Enamel Mug',    qty => 3, unit_price => '19.95'  },
    ];
    my $promo = { code => 'PERLMT20', kind => 'percent', value => '20.0000', min_subtotal => '0.0000' };
    my $done = 0;
    for (my $i = 0; $i < $iters; $i++) {
        my $r = Shop::Domain::Pricing::calculate($items, promo => $promo);
        $done++ if defined $r->{total};
    }
    return $done;
}

sub w_tui_screen {
    my ($iters, $is_unicode) = @_;
    my $scr = Shop::TUI::Screen->new(cols => 80, rows => 24, color_depth => '256');
    my $st_hdr = Shop::TUI::Screen::pack_style(fg => 97, bg => 44, bold => 1);
    my $st_row = Shop::TUI::Screen::pack_style(fg => 37);
    my $st_sel = Shop::TUI::Screen::pack_style(fg => 30, bg => 46, bold => 1);

    my @rows_ascii = (
        'VT-220   DEC VT220 Amber Terminal     Terminals        $429.00    12 in',
        'KB-M01   Model M Clicky Keyboard      Keyboards        $149.95    14 in',
        'AC-MUG   0xDEADBEEF Enamel Mug        Accessories       $19.95    42 in',
        'CF-ETH   Ethiopian Yirgacheffe 1lb    Coffee            $22.50    88 in',
        'SW-HDY   Post-Quantum Hoodie          Apparel           $68.00    19 in',
        'HW-YUB   Ed25519 Hardware Key         Security          $55.00    40 in',
    );
    my @rows_unicode = (
        "VT-220   \x{6771}\x{4EAC} Amber Terminal \x{1F5A5}\x{FE0F}    Terminals   \$429.00  12 in",
        "KB-M01   Caf\x{0065}\x{0301} Clicky Board \x{2328}\x{FE0F}     Keyboards   \$149.95  14 in",
        "AC-MUG   Dev Team \x{1F469}\x{200D}\x{1F4BB} Mug \x{2615}       Accessories  \$19.95  42 in",
        "CF-ETH   \x{30B3}\x{30FC}\x{30D2}\x{30FC} Roast \x{1F1EF}\x{1F1F5}         Coffee       \$22.50  88 in",
        "SW-HDY   PQ Hoodie \x{1F468}\x{200D}\x{1F469}\x{200D}\x{1F467}\x{200D}\x{1F466}       Apparel      \$68.00  19 in",
        "HW-YUB   Na\x{0069}\x{0308}ve Key \x{1F510} \x{1F1FA}\x{1F1F8}          Security     \$55.00  40 in",
    );

    my $rows_ref = $is_unicode ? \@rows_unicode : \@rows_ascii;
    my $n_rows   = scalar(@$rows_ref);
    my $done = 0;
    for (my $f = 0; $f < $iters; $f++) {
        my $sel = $f % 22;
        $scr->clear(0);
        $scr->write_str(0, 0, sprintf('%-80s', " perl5-mt-shop | Frame #$f"), $st_hdr, 80);
        for (my $y = 1; $y <= 22; $y++) {
            my $st = (($y - 1) == $sel) ? $st_sel : $st_row;
            $scr->write_str(2, $y, $rows_ref->[($y + $f) % $n_rows], $st, 76);
        }
        my $out = $scr->render();
        $done++ if defined $out;
    }
    return $done;
}

# ---------------------------------------------------------------------------
# Pre-freeze setup
# ---------------------------------------------------------------------------
my $tier1_ok = (
    MT::XS::is_threadsafe(\&Shop::SSH::Crypto::x25519_shared)
    && !MT::XS::is_remote(\&Shop::SSH::Crypto::x25519_shared)
    && MT::XS::is_threadsafe(\&Shop::SSH::Crypto::mlkem768_encapsulate)
    && MT::XS::is_threadsafe(\&Shop::SSH::Crypto::chacha20_poly1305_openssh_encrypt)
    && MT::XS::is_threadsafe(\&Shop::SSH::Crypto::aes256_gcm_openssh_encrypt)
    && MT::XS::is_threadsafe(\&Shop::SSH::Crypto::Zlib::deflate)
) ? 1 : 0;

my ($peer_sk, $peer_pk) = x25519_keypair();
my $mlkem_ek = _make_mlkem768_ek();
my ($test_ct, $test_ss) = mlkem768_encapsulate($mlkem_ek);
die "mlkem768_encapsulate pre-check failed\n" unless defined($test_ss) && length($test_ss) == 32;

my ($ed_sk, $ed_pk) = ed25519_keypair();
my $ed_msg = 'SSHv2 exchange hash benchmark payload ' . ('X' x 32);
my $ed_sig = ed25519_sign($ed_msg, $ed_sk);
die "ed25519_verify pre-check failed\n" unless ed25519_verify($ed_msg, $ed_sig, $ed_pk) == 1;

my $INITIAL_STOCK = 10_000;
my $inv = Shop::State::Inventory->new;
$inv->upsert_product({
    sku         => 'BENCH-CAS-SKU',
    name        => 'CAS Contention Item',
    category    => 'Bench',
    description => 'Lock-free MT::Cell CAS benchmark item',
    price       => '99.9500',
    stock       => $INITIAL_STOCK,
    active      => 1,
});
my $inv_ids = $inv->state_ids;

MT::Image::freeze();

# ---------------------------------------------------------------------------
# Runner helpers
# ---------------------------------------------------------------------------
sub run_workers {
    my ($n_workers, $fn_name, @args) = @_;
    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    my @ws;
    for (1 .. $n_workers) {
        push @ws, MT::Worker::spawn($fn_name, @args);
    }
    my $total = 0;
    for my $w (@ws) {
        $total += int(MT::Worker::join($w) // 0);
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
    $elapsed = 1e-6 if $elapsed <= 0;
    return ($total, $elapsed);
}

sub fmt_num {
    my ($n) = @_;
    my $s = sprintf('%.0f', $n);
    while ($s =~ s/^(-?\d+)(\d{3})/$1,$2/) {}
    return $s;
}

my @SCALE_WORKERS = (1, 4, 8);
my @CAS_WORKERS   = (1, 2, 4, 8);

# Iteration budgets (per worker)
my %ITERS = $smoke ? (
    x25519      => 1_500,
    mlkem768    => 1_000,
    ed25519_s   => 2_000,
    ed25519_v   => 1_000,
    chacha20    => 4_000,
    aes256gcm   => 4_000,
    zlib        => 400,
    cas_pairs   => 2_000,
    decimal     => 2_000,
    tui_ascii   => 100,
    tui_unicode => 50,
) : (
    x25519      => 8_000,
    mlkem768    => 6_000,
    ed25519_s   => 10_000,
    ed25519_v   => 5_000,
    chacha20    => 25_000,
    aes256gcm   => 25_000,
    zlib        => 2_000,
    cas_pairs   => 10_000,
    decimal     => 10_000,
    tui_ascii   => 400,
    tui_unicode => 200,
);

my $CIPHER_PAYLOAD_BYTES = 4096;

print "==========================================================================================\n";
printf " 03_crypto_cas_decimal: Tier-1 XS Crypto, CAS Inventory, MT::Decimal, TUI (%s mode)\n",
    ($smoke ? 'smoke' : 'full');
print "==========================================================================================\n\n";

# ---------------------------------------------------------------------------
# Section 1: Tier-1 XS Crypto & Zlib Scaling (1, 4, 8 workers)
# ---------------------------------------------------------------------------
my @crypto_specs = (
    { id => 'x25519_kex',       label => 'x25519 keypair+shared',          unit => 'ops/sec', fn => 'main::w_x25519',         args => [ $ITERS{x25519},    $peer_pk ] },
    { id => 'mlkem768_encap',   label => 'mlkem768_encapsulate',           unit => 'ops/sec', fn => 'main::w_mlkem768',       args => [ $ITERS{mlkem768},  $mlkem_ek ] },
    { id => 'ed25519_sign',     label => 'ed25519_sign',                   unit => 'ops/sec', fn => 'main::w_ed25519_sign',   args => [ $ITERS{ed25519_s}, $ed_sk, $ed_msg ] },
    { id => 'ed25519_verify',   label => 'ed25519_verify',                 unit => 'ops/sec', fn => 'main::w_ed25519_verify', args => [ $ITERS{ed25519_v}, $ed_pk, $ed_msg, $ed_sig ] },
    { id => 'chacha20_poly1305',label => 'chacha20-poly1305 encrypt (4K)', unit => 'MB/s',    fn => 'main::w_chacha20',       args => [ $ITERS{chacha20},  $CIPHER_PAYLOAD_BYTES ] },
    { id => 'aes256_gcm',       label => 'aes256-gcm encrypt (4K)',        unit => 'MB/s',    fn => 'main::w_aes256gcm',      args => [ $ITERS{aes256gcm}, $CIPHER_PAYLOAD_BYTES ] },
    { id => 'zlib_deflate_l5',  label => 'Zlib::deflate streaming (L5)',   unit => 'MB/s',    fn => 'main::w_zlib_deflate',   args => [ $ITERS{zlib},      5 ] },
);

my @crypto_results;
printf "[1] Tier-1 XS Crypto & Streaming Zlib (in-process=%s)\n", ($tier1_ok ? 'yes' : 'no');
printf "    %-32s %12s %12s %12s %8s %8s\n", 'Operation', '1w', '4w', '8w', 'Unit', '8w/1w';
printf "    %-32s %12s %12s %12s %8s %8s\n", '-' x 32, '-' x 12, '-' x 12, '-' x 12, '-' x 8, '-' x 8;

for my $spec (@crypto_specs) {
    my %by_w;
    for my $nw (@SCALE_WORKERS) {
        my ($total, $elapsed) = run_workers($nw, $spec->{fn}, @{ $spec->{args} });
        my $rate = ($spec->{unit} eq 'MB/s')
            ? ($total / (1024 * 1024)) / $elapsed
            : ($total / $elapsed);
        $by_w{$nw} = {
            workers     => $nw,
            total_units => $total,
            elapsed_sec => sprintf('%.4f', $elapsed) + 0,
            throughput  => sprintf('%.1f', $rate) + 0,
        };
    }
    my $r1 = $by_w{1}{throughput};
    my $r4 = $by_w{4}{throughput};
    my $r8 = $by_w{8}{throughput};
    my $speedup = $r1 > 0 ? ($r8 / $r1) : 0;

    if ($spec->{unit} eq 'MB/s') {
        printf "    %-32s %12.1f %12.1f %12.1f %8s %7.2fx\n",
            $spec->{label}, $r1, $r4, $r8, $spec->{unit}, $speedup;
    } else {
        printf "    %-32s %12s %12s %12s %8s %7.2fx\n",
            $spec->{label}, fmt_num($r1), fmt_num($r4), fmt_num($r8), $spec->{unit}, $speedup;
    }

    push @crypto_results, {
        id             => $spec->{id},
        label          => $spec->{label},
        unit           => $spec->{unit},
        scaling_8w_1w  => sprintf('%.2f', $speedup) + 0,
        workers        => \%by_w,
    };
}
print "\n";

# ---------------------------------------------------------------------------
# Section 2: Lock-Free MT::Cell CAS Inventory Contention (1, 2, 4, 8 workers)
# ---------------------------------------------------------------------------
my @cas_results;
print "[2] Lock-Free MT::Cell CAS Inventory Contention (single hot SKU)\n";
printf "    %-10s %14s %12s %14s %12s\n", 'Workers', 'CAS Ops', 'Elapsed ms', 'CAS ops/sec', 'Stock Check';
printf "    %-10s %14s %12s %14s %12s\n", '-' x 10, '-' x 14, '-' x 12, '-' x 14, '-' x 12;

for my $nw (@CAS_WORKERS) {
    my $ch = MT::Channel->new(32);
    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    my @ws;
    for (1 .. $nw) {
        push @ws, MT::Worker::spawn(
            'main::w_cas_inventory',
            $inv_ids->{products_id},
            $inv_ids->{cells_id},
            $ITERS{cas_pairs},
            $ch->id,
        );
    }
    MT::Worker::join($_) for @ws;
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
    $elapsed = 1e-6 if $elapsed <= 0;

    my $pairs_ok = 0;
    for (1 .. $nw) {
        $pairs_ok += int($ch->recv);
    }
    my $total_ops   = $pairs_ok * 2;
    my $ops_sec     = $total_ops / $elapsed;
    my $final_stock = $inv->get_stock('BENCH-CAS-SKU');
    my $zero_drift  = ($final_stock == $INITIAL_STOCK) ? 1 : 0;

    printf "    %-10d %14s %12.2f %14s %12s\n",
        $nw, fmt_num($total_ops), $elapsed * 1000, fmt_num($ops_sec),
        ($zero_drift ? 'ZERO DRIFT' : "DRIFT($final_stock)");

    push @cas_results, {
        workers        => $nw,
        total_cas_ops  => $total_ops,
        elapsed_sec    => sprintf('%.4f', $elapsed) + 0,
        ops_per_sec    => sprintf('%.1f', $ops_sec) + 0,
        initial_stock  => $INITIAL_STOCK,
        final_stock    => int($final_stock),
        zero_drift     => $zero_drift ? JSON::PP::true : JSON::PP::false,
    };
}
print "\n";

# ---------------------------------------------------------------------------
# Section 3: MT::Decimal Checkout Pricing (1, 4, 8 workers)
# ---------------------------------------------------------------------------
my %dec_by_w;
for my $nw (@SCALE_WORKERS) {
    my ($total, $elapsed) = run_workers($nw, 'main::w_decimal_pricing', $ITERS{decimal});
    $dec_by_w{$nw} = {
        workers       => $nw,
        total_calcs   => $total,
        elapsed_sec   => sprintf('%.4f', $elapsed) + 0,
        calcs_per_sec => sprintf('%.1f', $total / $elapsed) + 0,
    };
}
my $dec_speedup = $dec_by_w{1}{calcs_per_sec} > 0
    ? ($dec_by_w{8}{calcs_per_sec} / $dec_by_w{1}{calcs_per_sec})
    : 0;

print "[3] MT::Decimal (IEEE 754-2008 decimal128) Checkout Pricing\n";
printf "    1w: %s calcs/sec | 4w: %s calcs/sec | 8w: %s calcs/sec (%.2fx scaling)\n\n",
    fmt_num($dec_by_w{1}{calcs_per_sec}),
    fmt_num($dec_by_w{4}{calcs_per_sec}),
    fmt_num($dec_by_w{8}{calcs_per_sec}),
    $dec_speedup;

# ---------------------------------------------------------------------------
# Section 4: Shop::TUI::Screen ASCII Fast-Path vs UAX #29 Unicode/ZWJ
# ---------------------------------------------------------------------------
my %tui_ascii_w;
my %tui_unicode_w;
for my $nw (@SCALE_WORKERS) {
    my ($ta, $ea) = run_workers($nw, 'main::w_tui_screen', $ITERS{tui_ascii}, 0);
    $tui_ascii_w{$nw} = {
        workers        => $nw,
        total_frames   => $ta,
        elapsed_sec    => sprintf('%.4f', $ea) + 0,
        frames_per_sec => sprintf('%.1f', $ta / $ea) + 0,
    };

    my ($tu, $eu) = run_workers($nw, 'main::w_tui_screen', $ITERS{tui_unicode}, 1);
    $tui_unicode_w{$nw} = {
        workers        => $nw,
        total_frames   => $tu,
        elapsed_sec    => sprintf('%.4f', $eu) + 0,
        frames_per_sec => sprintf('%.1f', $tu / $eu) + 0,
    };
}

my $ascii_vs_uni_1w = $tui_unicode_w{1}{frames_per_sec} > 0
    ? ($tui_ascii_w{1}{frames_per_sec} / $tui_unicode_w{1}{frames_per_sec})
    : 0;

print "[4] Shop::TUI::Screen Rendering (80x24): ASCII Fast-Path vs UAX #29 Unicode/ZWJ\n";
printf "    %-28s %12s %12s %12s %8s\n", 'Path', '1w (fps)', '4w (fps)', '8w (fps)', '8w/1w';
printf "    %-28s %12s %12s %12s %8s\n", '-' x 28, '-' x 12, '-' x 12, '-' x 12, '-' x 8;
printf "    %-28s %12s %12s %12s %7.2fx\n",
    'ASCII fast-path',
    fmt_num($tui_ascii_w{1}{frames_per_sec}),
    fmt_num($tui_ascii_w{4}{frames_per_sec}),
    fmt_num($tui_ascii_w{8}{frames_per_sec}),
    ($tui_ascii_w{1}{frames_per_sec} > 0 ? $tui_ascii_w{8}{frames_per_sec} / $tui_ascii_w{1}{frames_per_sec} : 0);
printf "    %-28s %12s %12s %12s %7.2fx\n",
    'UAX #29 Unicode/ZWJ/CJK',
    fmt_num($tui_unicode_w{1}{frames_per_sec}),
    fmt_num($tui_unicode_w{4}{frames_per_sec}),
    fmt_num($tui_unicode_w{8}{frames_per_sec}),
    ($tui_unicode_w{1}{frames_per_sec} > 0 ? $tui_unicode_w{8}{frames_per_sec} / $tui_unicode_w{1}{frames_per_sec} : 0);
printf "    1w ASCII / Unicode ratio: %.2fx\n", $ascii_vs_uni_1w;
print "==========================================================================================\n";

my $result = {
    benchmark            => '03_crypto_cas_decimal',
    mode                 => $smoke ? 'smoke' : 'full',
    tier1_xs_in_process  => $tier1_ok ? JSON::PP::true : JSON::PP::false,
    cipher_payload_bytes => $CIPHER_PAYLOAD_BYTES,
    crypto               => \@crypto_results,
    cas_inventory        => \@cas_results,
    decimal_pricing      => {
        scaling_8w_1w => sprintf('%.2f', $dec_speedup) + 0,
        workers       => \%dec_by_w,
    },
    tui_screen => {
        ascii_vs_unicode_1w_ratio => sprintf('%.2f', $ascii_vs_uni_1w) + 0,
        ascii_fast_path => {
            scaling_8w_1w => sprintf('%.2f', ($tui_ascii_w{1}{frames_per_sec} > 0 ? $tui_ascii_w{8}{frames_per_sec} / $tui_ascii_w{1}{frames_per_sec} : 0)) + 0,
            workers       => \%tui_ascii_w,
        },
        unicode_zwj_uax29 => {
            scaling_8w_1w => sprintf('%.2f', ($tui_unicode_w{1}{frames_per_sec} > 0 ? $tui_unicode_w{8}{frames_per_sec} / $tui_unicode_w{1}{frames_per_sec} : 0)) + 0,
            workers       => \%tui_unicode_w,
        },
    },
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
