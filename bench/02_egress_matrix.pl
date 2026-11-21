#!/usr/bin/env perl
use strict;
use warnings;

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

use Shop::TUI::Screen;
use Shop::SSH::Crypto;

my $frames    = 100;
my $cols      = 80;
my $rows      = 24;
my $smoke     = 0;
my $json_path = '';

GetOptions(
    'frames=i' => \$frames,
    'cols=i'   => \$cols,
    'rows=i'   => \$rows,
    'smoke!'   => \$smoke,
    'json=s'   => \$json_path,
) or die "Usage: $0 [--frames N] [--cols N] [--rows N] [--smoke] [--json path]\n";

if ($smoke && $frames == 100) {
    $frames = 30;
}
$frames = 10 if $frames < 10;

my @ZLIB_LEVELS = (1, 3, 5, 6, 9);

my @CATALOG = (
    [ 'VT-220', 'DEC VT220 Amber Terminal',  'Terminals',   429.00, 12 ],
    [ 'KB-M01', 'Model M Clicky Keyboard',   'Keyboards',   149.95, 14 ],
    [ 'AC-MUG', '0xDEADBEEF Enamel Mug',     'Accessories',  19.95, 42 ],
    [ 'CF-ETH', 'Ethiopian Yirgacheffe 1lb', 'Coffee',       22.50, 88 ],
    [ 'CF-COL', 'Colombian Supremo 1lb',     'Coffee',       19.50, 64 ],
    [ 'SW-TEE', 'perl5-mt Fiber Tee (XL)',   'Apparel',      34.00, 25 ],
    [ 'SW-HDY', 'Post-Quantum Hoodie',       'Apparel',      68.00, 19 ],
    [ 'BK-CAM', 'Camel & Fibers Hardcover',  'Books',        54.00, 31 ],
    [ 'HW-YUB', 'Ed25519 Hardware Key',      'Security',     55.00, 40 ],
    [ 'AC-STK', 'ML-KEM-768 Sticker Pack',   'Accessories',   8.50, 120 ],
);

my $st_hdr = Shop::TUI::Screen::pack_style(fg => 97, bg => 44, bold => 1);
my $st_box = Shop::TUI::Screen::pack_style(fg => 36);
my $st_sel = Shop::TUI::Screen::pack_style(fg => 30, bg => 46, bold => 1);
my $st_row = Shop::TUI::Screen::pack_style(fg => 37);
my $st_dim = Shop::TUI::Screen::pack_style(fg => 90, dim => 1);
my $st_grn = Shop::TUI::Screen::pack_style(fg => 92, bold => 1);
my $st_ylw = Shop::TUI::Screen::pack_style(fg => 93, bold => 1);

my $resize_up_frame   = int($frames * 0.60);
my $resize_down_frame = int($frames * 0.75);

sub draw_frame {
    my ($scr, $f, $stocks, $cart_qty, $cart_total) = @_;
    my $c = $scr->cols;
    my $r = $scr->rows;

    my $sel_idx = $f % scalar(@CATALOG);
    $scr->clear(0);

    my $hdr = sprintf(
        ' perl5-mt-shop | [PQ:MLKEM768] [ZLIB] [CAS] | Cart(%d: $%.2f) | Frame #%d',
        $$cart_qty, $$cart_total, $f
    );
    $scr->write_str(0, 0, sprintf("%-${c}s", $hdr), $st_hdr, $c);

    my $box_h = $r - 3;
    $scr->box(0, 1, $c, $box_h, $st_box, 'Catalog');
    $scr->write_str(2, 2, sprintf('%-8s %-28s %-14s %9s %8s', 'SKU', 'PRODUCT', 'CATEGORY', 'PRICE', 'STOCK'), $st_dim, $c - 4);

    my $max_rows = $box_h - 6;
    $max_rows = scalar(@CATALOG) if $max_rows > scalar(@CATALOG);
    for my $i (0 .. $max_rows - 1) {
        my $p   = $CATALOG[$i];
        my $stk = $stocks->[$i];
        my $txt = sprintf('%-8s %-28s %-14s $%8.2f %5d in', $p->[0], $p->[1], $p->[2], $p->[3], $stk);
        my $st  = ($i == $sel_idx) ? $st_sel : $st_row;
        $scr->write_str(2, 4 + $i, $txt, $st, $c - 4);
    }

    my $cur = $CATALOG[$sel_idx];
    my $detail_y = $r - 6;
    $detail_y = 15 if $detail_y < 15;
    if ($detail_y < $r - 2) {
        $scr->write_str(2, $detail_y, sprintf('Selected: %s (%s) - $%.2f | Stock: %d', $cur->[1], $cur->[0], $cur->[3], $stocks->[$sel_idx]), $st_grn, $c - 4);
    }
    if ($detail_y + 1 < $r - 2) {
        $scr->write_str(2, $detail_y + 1, sprintf('Cart: %d items | Subtotal: $%.2f | Live stock updates active', $$cart_qty, $$cart_total), $st_ylw, $c - 4);
    }
    if ($r - 3 > $detail_y + 1) {
        $scr->write_str(2, $r - 3, '[j/k] Move  [a] Add  [R] Reorder  [c] Cart  [o] Orders  [q] Quit', $st_dim, $c - 4);
    }

    my $foot = sprintf(' Status: %dx%d | Active Stock CAS: OK | Event #%d', $c, $r, $f);
    $scr->write_str(0, $r - 1, sprintf("%-${c}s", $foot), $st_dim, $c);
}

sub sgr_for_style {
    my ($st) = @_;
    return "\e[0m" if $st == 0;
    my $fg = $st & 0x1ffffff;
    my $bg = ($st >> 25) & 0x1ffffff;
    my $fl = ($st >> 50) & 0xf;
    my @p = (0);
    push @p, 1 if $fl & 1;
    push @p, 2 if $fl & 2;
    push @p, 7 if $fl & 4;
    push @p, 4 if $fl & 8;
    push @p, $fg if $fg > 0 && $fg < 256;
    push @p, $bg if $bg > 0 && $bg < 256;
    return "\e[" . join(';', @p) . 'm';
}

sub extract_grid_lines {
    my ($scr) = @_;
    my $c       = $scr->cols;
    my $r       = $scr->rows;
    my $curr_ch = $scr->{curr_ch};
    my $curr_st = $scr->{curr_st};
    my $g_list  = $scr->{_g_by_id} || [];
    my @lines;
    $#lines = $r - 1;

    for (my $y = 0; $y < $r; $y++) {
        my $row_str = '';
        my $base    = $y * $c;
        my $last_st = -1;
        for (my $x = 0; $x < $c; $x++) {
            my $cp = $curr_ch->[$base + $x];
            next if $cp < 0;
            my $st = $curr_st->[$base + $x];
            if ($st != $last_st) {
                $row_str .= sgr_for_style($st);
                $last_st = $st;
            }
            if ($cp >= 0x200000) {
                my $g = $g_list->[$cp - 0x200000];
                $row_str .= defined($g) ? $g : ' ';
            } elsif ($cp >= 32) {
                my $ch = chr($cp);
                utf8::encode($ch) if $cp > 127;
                $row_str .= $ch;
            } else {
                $row_str .= ' ';
            }
        }
        $lines[$y] = $row_str;
    }
    return \@lines;
}

# Run single workload pass to collect exact ANSI buffers and baseline timings
my $scr = Shop::TUI::Screen->new(cols => $cols, rows => $rows, color_depth => '256');
my @stocks = map { $_->[4] } @CATALOG;
my $cart_qty   = 0;
my $cart_total = 0.0;

my $full_bytes     = 0;
my $line_bytes     = 0;
my $cell_bytes     = 0;
my $full_sec       = 0.0;
my $line_sec       = 0.0;
my $cell_render_sec = 0.0;
my $resize_events  = 0;

my @prev_lines = ('') x $rows;
my @diff_frames;

for (my $f = 0; $f < $frames; $f++) {
    # Live stock update every 4 frames
    if ($f > 0 && ($f % 4) == 0) {
        my $idx = ($f / 4) % scalar(@CATALOG);
        $stocks[$idx]-- if $stocks[$idx] > 1;
    }
    # Cart update every 7 frames
    if ($f > 0 && ($f % 7) == 0) {
        my $idx = $f % scalar(@CATALOG);
        $cart_qty++;
        $cart_total += $CATALOG[$idx][3];
    }
    # Terminal resize events
    if ($f == $resize_up_frame) {
        $scr->resize($cols + 20, $rows + 6);
        @prev_lines = ('') x ($rows + 6);
        $resize_events++;
    } elsif ($f == $resize_down_frame) {
        $scr->resize($cols, $rows);
        @prev_lines = ('') x $rows;
        $resize_events++;
    }

    draw_frame($scr, $f, \@stocks, \$cart_qty, \$cart_total);

    # Full-frame ANSI serialization
    my $t_f0   = clock_gettime(CLOCK_MONOTONIC);
    my $lines  = extract_grid_lines($scr);
    my $full_s = "\e[2J\e[H" . join("\r\n", @$lines);
    my $t_f1   = clock_gettime(CLOCK_MONOTONIC);
    $full_sec   += ($t_f1 - $t_f0);
    $full_bytes += length($full_s);

    # Line-diff ANSI serialization
    my $t_l0   = clock_gettime(CLOCK_MONOTONIC);
    my $ldiff  = '';
    my $nr     = scalar(@$lines);
    for (my $y = 0; $y < $nr; $y++) {
        if (!defined($prev_lines[$y]) || $lines->[$y] ne $prev_lines[$y]) {
            $ldiff .= sprintf("\e[%d;1H%s", $y + 1, $lines->[$y]);
            $prev_lines[$y] = $lines->[$y];
        }
    }
    my $t_l1   = clock_gettime(CLOCK_MONOTONIC);
    $line_sec   += ($t_l1 - $t_l0) + ($t_f1 - $t_f0);
    $line_bytes += length($ldiff);

    # Shop::TUI::Screen cell-diff render
    my $t_c0 = clock_gettime(CLOCK_MONOTONIC);
    my $diff = $scr->render();
    my $t_c1 = clock_gettime(CLOCK_MONOTONIC);
    $cell_render_sec += ($t_c1 - $t_c0);
    $cell_bytes      += length($diff);
    push @diff_frames, $diff;
}

# Repeat cell-diff render pass if needed for stable microsecond timing
my $render_passes = 1;
if ($cell_render_sec < 0.05) {
    my $reps = $smoke ? 3 : 8;
    my $scr2 = Shop::TUI::Screen->new(cols => $cols, rows => $rows, color_depth => '256');
    my $t0   = clock_gettime(CLOCK_MONOTONIC);
    my $acc  = 0.0;
    for (1 .. $reps) {
        my @st2 = map { $_->[4] } @CATALOG;
        my ($cq2, $ct2) = (0, 0.0);
        $scr2->resize($cols, $rows);
        $scr2->invalidate();
        for (my $f = 0; $f < $frames; $f++) {
            if ($f > 0 && ($f % 4) == 0) {
                my $idx = ($f / 4) % scalar(@CATALOG);
                $st2[$idx]-- if $st2[$idx] > 1;
            }
            if ($f > 0 && ($f % 7) == 0) {
                my $idx = $f % scalar(@CATALOG);
                $cq2++;
                $ct2 += $CATALOG[$idx][3];
            }
            $scr2->resize($cols + 20, $rows + 6) if $f == $resize_up_frame;
            $scr2->resize($cols, $rows)          if $f == $resize_down_frame;
            draw_frame($scr2, $f, \@st2, \$cq2, \$ct2);
            my $tr0 = clock_gettime(CLOCK_MONOTONIC);
            my $d   = $scr2->render();
            my $tr1 = clock_gettime(CLOCK_MONOTONIC);
            $acc += ($tr1 - $tr0);
        }
    }
    $cell_render_sec = $acc / $reps;
    $render_passes   = $reps;
}

my $cell_render_us = ($cell_render_sec / $frames) * 1e6;
my $full_us        = ($full_sec / $frames) * 1e6;
my $line_us        = ($line_sec / $frames) * 1e6;

sub build_mode_entry {
    my (%a) = @_;
    my $bytes   = $a{total_bytes};
    my $savings = $full_bytes > 0 ? (1.0 - ($bytes / $full_bytes)) * 100.0 : 0.0;
    my $factor  = $bytes > 0 ? ($full_bytes / $bytes) : 0.0;
    my $gb_1m   = ($bytes * 1_000_000) / (1024 ** 3);
    return {
        id                   => $a{id},
        label                => $a{label},
        compression          => $a{compression},
        zlib_level           => $a{zlib_level},
        total_bytes          => int($bytes),
        bytes_per_frame      => sprintf('%.1f', $bytes / $frames) + 0,
        savings_vs_full_pct  => sprintf('%.2f', $savings) + 0,
        reduction_factor     => sprintf('%.2f', $factor) + 0,
        render_us_per_frame  => sprintf('%.1f', $a{render_us}) + 0,
        deflate_us_per_frame => sprintf('%.1f', $a{deflate_us}) + 0,
        total_us_per_frame   => sprintf('%.1f', $a{render_us} + $a{deflate_us}) + 0,
        gb_per_1m_sessions   => sprintf('%.2f', $gb_1m) + 0,
    };
}

my @modes;
push @modes, build_mode_entry(
    id          => 'full_frame_raw',
    label       => 'Full-frame uncompressed ANSI',
    compression => 'none',
    zlib_level  => undef,
    total_bytes => $full_bytes,
    render_us   => $full_us,
    deflate_us  => 0.0,
);
push @modes, build_mode_entry(
    id          => 'line_diff_raw',
    label       => 'Line-diff uncompressed ANSI',
    compression => 'none',
    zlib_level  => undef,
    total_bytes => $line_bytes,
    render_us   => $line_us,
    deflate_us  => 0.0,
);
push @modes, build_mode_entry(
    id          => 'cell_diff_raw',
    label       => 'Shop::TUI::Screen cell-diff raw',
    compression => 'none',
    zlib_level  => undef,
    total_bytes => $cell_bytes,
    render_us   => $cell_render_us,
    deflate_us  => 0.0,
);

# Measure zlib@openssh.com streaming compression across levels 1, 3, 5, 6, 9
my $zlib_reps = $smoke ? 5 : 20;
for my $lvl (@ZLIB_LEVELS) {
    my $wire_bytes = 0;
    my $z_once = Shop::SSH::Crypto::Zlib->new($lvl);
    for my $chunk (@diff_frames) {
        if (length($chunk)) {
            $wire_bytes += length($z_once->deflate($chunk));
        }
    }

    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    for (1 .. $zlib_reps) {
        my $z = Shop::SSH::Crypto::Zlib->new($lvl);
        for my $chunk (@diff_frames) {
            if (length($chunk)) {
                my $out = $z->deflate($chunk);
            }
        }
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
    my $deflate_us = ($elapsed / ($zlib_reps * $frames)) * 1e6;

    push @modes, build_mode_entry(
        id          => "cell_diff_zlib_l$lvl",
        label       => "Cell-diff + zlib\@openssh.com (level $lvl)",
        compression => 'zlib@openssh.com',
        zlib_level  => $lvl,
        total_bytes => $wire_bytes,
        render_us   => $cell_render_us,
        deflate_us  => $deflate_us,
    );
}

sub fmt_int {
    my ($n) = @_;
    my $s = sprintf('%.0f', $n);
    while ($s =~ s/^(-?\d+)(\d{3})/$1,$2/) {}
    return $s;
}

print "==========================================================================================\n";
printf " 02_egress_matrix: %d-Frame %dx%d Interactive TUI Workload (%s mode, %d resize events)\n",
    $frames, $cols, $rows, ($smoke ? 'smoke' : 'full'), $resize_events;
print "==========================================================================================\n";
printf "%-40s %10s %8s %8s %9s %9s %9s\n",
    'Mode', 'Wire Bytes', 'Bytes/f', 'Savings', 'Render us', 'Zlib us', 'Total us';
printf "%-40s %10s %8s %8s %9s %9s %9s\n",
    '-' x 40, '-' x 10, '-' x 8, '-' x 8, '-' x 9, '-' x 9, '-' x 9;

for my $m (@modes) {
    printf "%-40s %10s %8.1f %7.2f%% %9.1f %9.1f %9.1f\n",
        $m->{label},
        fmt_int($m->{total_bytes}),
        $m->{bytes_per_frame},
        $m->{savings_vs_full_pct},
        $m->{render_us_per_frame},
        $m->{deflate_us_per_frame},
        $m->{total_us_per_frame};
}
print "==========================================================================================\n";

my $result = {
    benchmark         => '02_egress_matrix',
    mode              => $smoke ? 'smoke' : 'full',
    frames            => int($frames),
    initial_size      => { cols => int($cols), rows => int($rows) },
    resize_events     => int($resize_events),
    packed_array_type => "MT::Array::packed('IV')",
    render_passes     => int($render_passes),
    zlib_timing_reps  => int($zlib_reps),
    modes             => \@modes,
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
