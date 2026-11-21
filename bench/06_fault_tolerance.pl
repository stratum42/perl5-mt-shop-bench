#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);

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
use IO::Socket::INET;
use JSON::PP ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

use MT;
use MT::Cell;
use MT::Channel;
use MT::Checkpoint;
use MT::Decimal;
use MT::Fault;
use MT::Fiber;
use MT::Pool;
use MT::SharedHash;
use MT::Supervisor;

use Shop::Cache::KeyDB;
use Shop::DB;
use Shop::Domain::Pricing;
use Shop::State::EventBus;
use Shop::State::Inventory;

my $smoke     = 0;
my $json_path = '';

GetOptions(
    'smoke!' => \$smoke,
    'json=s' => \$json_path,
) or die "Usage: $0 [--smoke] [--json path]\n";

$SIG{PIPE} = 'IGNORE';

# ---------------------------------------------------------------------------
# Constants and worker entrypoints (defined before MT::Image::freeze)
# ---------------------------------------------------------------------------

use constant SEALED_TAX_RATE => '0.0825';
my $IMMORTAL_YES = \!!1;

sub w_mutate_boot_image {
    my ($out_id) = @_;
    my $out = MT::Channel->attach($out_id);

    my $imm_ok = 0;
    eval { Internals::SvREFCNT($$IMMORTAL_YES, 5) };
    $imm_ok = 1 if ($@ // '') =~ /MT_IMMORTAL_MUTATION/;

    my $ro_ok = 0;
    eval {
        my $ref = \SEALED_TAX_RATE();
        $$ref = '0.9900';
    };
    $ro_ok = 1 if ($@ // '') =~ /read-only/i;

    $out->send("$imm_ok:$ro_ok");
    return 1;
}

sub w_sibling_cas_decimal {
    my ($p_id, $c_id, $iters) = @_;
    my $inv = Shop::State::Inventory->attach({ products_id => $p_id, cells_id => $c_id });
    my $ok_ops = 0;
    my $last_total = '';
    for (1 .. $iters) {
        my ($ok) = $inv->reserve('VT-220', 1);
        if ($ok) {
            $inv->release('VT-220', 1);
            $ok_ops++;
        }
        my $quote = Shop::Domain::Pricing::calculate(
            [{ sku => 'VT-220', name => 'VT220', qty => 2, unit_price => '429.0000' }],
            tax_rate => SEALED_TAX_RATE,
        );
        $last_total = '' . $quote->{total};
    }
    return "$ok_ops:$last_total";
}

sub w_hung_heartbeat {
    my ($in_id, $out_id) = @_;
    my $in  = MT::Channel->attach($in_id);
    my $out = MT::Channel->attach($out_id);
    MT::Supervisor::beat();
    MT::Supervisor::_pause_heartbeat(1);
    $out->send('paused');
    $in->recv();
    return 1;
}

sub w_healthy_heartbeat {
    my ($in_id, $out_id) = @_;
    my $in  = MT::Channel->attach($in_id);
    my $out = MT::Channel->attach($out_id);
    MT::Supervisor::beat();
    $out->send('alive');
    my $beats = 1;
    while (1) {
        my ($got, $msg) = $in->try_recv;
        last if $got && defined $msg && $msg eq 'stop';
        MT::Supervisor::beat();
        $beats++;
        sleep(0.02);
    }
    return $beats;
}

sub paired_checkout_batch {
    my ($spec) = @_;
    my ($total_orders, $crash_at) = split /:/, $spec;
    my $state = MT::Checkpoint::restore() // {
        step       => 0,
        cents_acc  => 0,
        resumed    => 0,
        ckpt_count => 0,
    };
    $state->{resumed} = 1 if MT::Checkpoint::is_backup();

    while ($state->{step} < $total_orders) {
        $state->{step}++;
        $state->{cents_acc} += ($state->{step} * 1995);
        if ($state->{step} % 500 == 0) {
            $state->{ckpt_count}++;
            MT::Checkpoint::save($state);
        }
        if ($crash_at > 0 && $state->{step} == $crash_at && !MT::Checkpoint::is_backup()) {
            MT::Fault::_trigger_sigsegv();
        }
    }
    return $state;
}

sub w_fiber_isolation {
    my ($n_fibers) = @_;
    my @fibers;
    my $ok_count  = 0;
    my $err_count = 0;

    for my $i (1 .. $n_fibers) {
        my $should_die = ($i == 3 || $i == 7) ? 1 : 0;
        my $fid = MT::Fiber::spawn(sub {
            my ($idx, $fail) = @_;
            my $out;
            my $ok = eval {
                MT::Fiber::yield("s1:$idx");
                die "simulated fiber fault $idx\n" if $fail;
                my $q = Shop::Domain::Pricing::calculate(
                    [{ sku => "SKU-$idx", qty => $idx, unit_price => '10.00' }],
                    tax_rate => '0.0800',
                );
                MT::Fiber::yield("s2:$idx");
                $out = "ok:$idx:" . $q->{total};
                1;
            };
            return $ok ? $out : "ERR:$idx:$@";
        }, $i, $should_die);
        push @fibers, { id => $fid, idx => $i };
    }

    my $active = scalar(@fibers);
    while ($active > 0) {
        $active = 0;
        for my $f (@fibers) {
            next if $f->{done};
            MT::Fiber::resume($f->{id});
            if (MT::Fiber::is_finished($f->{id})) {
                my $res = MT::Fiber::join($f->{id});
                if (defined $res && $res =~ /^ERR:/) {
                    $err_count++;
                }
                elsif (defined $res && $res =~ /^ok:/) {
                    $ok_count++;
                }
                $f->{done} = 1;
            }
            else {
                $active++;
            }
        }
    }

    my $leaked = MT::Fiber::count();
    return "$ok_count:$err_count:$leaked";
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub percentile {
    my ($arr, $p) = @_;
    return 0 unless @$arr;
    my @sorted = sort { $a <=> $b } @$arr;
    my $idx = int(($p / 100.0) * $#sorted + 0.5);
    $idx = 0 if $idx < 0;
    $idx = $#sorted if $idx > $#sorted;
    return $sorted[$idx];
}

sub stats_from_samples {
    my ($samples) = @_;
    return { p50_ms => 0, p95_ms => 0, min_ms => 0, max_ms => 0 } unless @$samples;
    my @sorted = sort { $a <=> $b } @$samples;
    return {
        p50_ms => 0 + sprintf('%.3f', percentile(\@sorted, 50)),
        p95_ms => 0 + sprintf('%.3f', percentile(\@sorted, 95)),
        min_ms => 0 + sprintf('%.3f', $sorted[0]),
        max_ms => 0 + sprintf('%.3f', $sorted[-1]),
    };
}

# ---------------------------------------------------------------------------
# Seed shared inventory and freeze boot image
# ---------------------------------------------------------------------------

my $inv = Shop::State::Inventory->new;
$inv->upsert_product({
    sku         => 'VT-220',
    name        => 'DEC VT220 Amber Terminal',
    category    => 'Terminals',
    description => 'Amber CRT serial terminal',
    price       => '429.0000',
    stock       => 100,
    active      => 1,
});
$inv->upsert_product({
    sku         => 'AC-MUG',
    name        => 'Enamel Mug',
    category    => 'Accessories',
    description => '0xDEADBEEF mug',
    price       => '19.9500',
    stock       => 50,
    active      => 1,
});

MT::Image::freeze();
MT::Fault::reset();

my $hb_cfg = MT::Supervisor::config();
my @scenarios;
my $total_collateral_drops = 0;

# ---------------------------------------------------------------------------
# Scenario 1: Sealed Boot Image Isolation
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 2 : 5;
    my $sib_iters = $smoke ? 25 : 100;
    my ($passed, $failed) = (0, 0);
    my @latencies;
    my $inv_ids = $inv->state_ids;

    for (1 .. $trials) {
        my $err_ch = MT::Channel->new(4);
        my $t0 = clock_gettime(CLOCK_MONOTONIC);
        my $w_mut = MT::Worker::spawn('main::w_mutate_boot_image', $err_ch->id);
        my $w_sib = MT::Worker::spawn('main::w_sibling_cas_decimal', $inv_ids->{products_id}, $inv_ids->{cells_id}, $sib_iters);
        MT::Worker::join($w_mut);
        my $sib_res = MT::Worker::join($w_sib);
        my $dt_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;
        my $trapped = $err_ch->recv;

        my $ok = ($trapped eq '1:1' && $sib_res eq "$sib_iters:928.79" && $inv->get_stock('VT-220') == 100) ? 1 : 0;
        $ok ? $passed++ : $failed++;
        $total_collateral_drops++ unless $ok;
        push @latencies, $dt_ms;
    }

    my $st = stats_from_samples(\@latencies);
    push @scenarios, {
        id       => 'sealed_boot_image_isolation',
        label    => 'Sealed boot image isolation',
        metric   => 'trap + sibling ops',
        trials   => $trials,
        passed   => $passed,
        failed   => $failed,
        %$st,
        detail   => "MT_IMMORTAL_MUTATION + read-only trapped; $passed/$trials sibling CAS+Decimal intact",
    };
}

# ---------------------------------------------------------------------------
# Scenario 2: MT::Supervisor + MT::Fault Heartbeat Detection
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 1 : 3;
    my ($passed, $failed) = (0, 0);
    my @latencies;

    for (1 .. $trials) {
        MT::Fault::reset();
        my @captured;
        MT::Fault::on(sub { push @captured, $_[0] });

        my $hung_in  = MT::Channel->new(4);
        my $hung_out = MT::Channel->new(4);
        my $good_in  = MT::Channel->new(4);
        my $good_out = MT::Channel->new(4);

        my $w_hung = MT::Worker::spawn('main::w_hung_heartbeat', $hung_in->id, $hung_out->id);
        my $w_good = MT::Worker::spawn('main::w_healthy_heartbeat', $good_in->id, $good_out->id);

        my $m1 = $hung_out->recv;
        my $m2 = $good_out->recv;

        my $t0 = clock_gettime(CLOCK_MONOTONIC);
        my $detected = 0;
        while (clock_gettime(CLOCK_MONOTONIC) - $t0 < 3.0) {
            if (MT::Supervisor::tick() > 0) {
                $detected = 1;
                last;
            }
            sleep(0.005);
        }
        my $detect_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;

        my $status = MT::Supervisor::status();
        my ($st_hung) = grep { $_->{unit_kind} eq 'worker' && $_->{unit_id} == $w_hung } @$status;
        my ($st_good) = grep { $_->{unit_kind} eq 'worker' && $_->{unit_id} == $w_good } @$status;

        $hung_in->send('stop');
        $good_in->send('stop');
        MT::Worker::join($w_hung);
        my $beats = MT::Worker::join($w_good);

        my ($hb_fault) = grep { ($_->{cause} // '') eq 'HEARTBEAT_TIMEOUT' && $_->{unit_id} == $w_hung } @captured;
        my $ok = ($m1 eq 'paused' && $m2 eq 'alive' && $detected && defined $hb_fault
            && ($st_hung && $st_hung->{state} eq 'faulted')
            && ($st_good && $st_good->{state} eq 'live')
            && $beats >= 2) ? 1 : 0;

        $ok ? $passed++ : $failed++;
        $total_collateral_drops++ unless ($st_good && $st_good->{state} eq 'live');
        push @latencies, $detect_ms;
    }

    my $st = stats_from_samples(\@latencies);
    push @scenarios, {
        id       => 'supervisor_heartbeat_detection',
        label    => 'Supervisor heartbeat detection',
        metric   => 'detection latency',
        trials   => $trials,
        passed   => $passed,
        failed   => $failed,
        %$st,
        detail   => sprintf('schedule %dms x %d misses; healthy sibling stayed live', $hb_cfg->{heartbeat_ms}, $hb_cfg->{heartbeat_miss}),
    };
}

# ---------------------------------------------------------------------------
# Scenario 3: MT::Pool Supervised Respawn & pairs => 1 Primary/Backup Failover
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 2 : 5;
    my ($passed, $failed) = (0, 0);
    my @takeover_samples;
    my @e2e_samples;

    my $pool = MT::Pool->new(workers => 2, pairs => 1, max_restarts => 16, backoff_base_ms => 5);
    my $ref = $pool->run(\&paired_checkout_batch, '2000:0')->join;

    for (1 .. $trials) {
        my $prev_takeovers = $pool->takeovers;
        my $t0  = clock_gettime(CLOCK_MONOTONIC);
        my $res = $pool->run(\&paired_checkout_batch, '2000:1250')->join;
        my $e2e_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;
        my $tk_ms  = $pool->last_takeover_ms;

        my $ok = ($res->{step} == 2000
            && $res->{cents_acc} == $ref->{cents_acc}
            && $res->{resumed} == 1
            && $pool->takeovers == $prev_takeovers + 1) ? 1 : 0;

        $ok ? $passed++ : $failed++;
        $total_collateral_drops++ unless $ok;
        push @takeover_samples, $tk_ms;
        push @e2e_samples, $e2e_ms;
    }
    $pool->shutdown;

    my $st = stats_from_samples(\@takeover_samples);
    my $e2e_st = stats_from_samples(\@e2e_samples);
    push @scenarios, {
        id         => 'pool_pairs_failover',
        label      => 'MT::Pool pairs => 1 failover',
        metric     => 'backup takeover',
        trials     => $trials,
        passed     => $passed,
        failed     => $failed,
        %$st,
        e2e_p50_ms => $e2e_st->{p50_ms},
        e2e_p95_ms => $e2e_st->{p95_ms},
        detail     => sprintf('SIGSEGV on primary; backup restored checkpoint (e2e p50 %.2f ms)', $e2e_st->{p50_ms}),
    };
}

# ---------------------------------------------------------------------------
# Scenario 4: Per-Fiber Crash Isolation
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 3 : 10;
    my ($passed, $failed) = (0, 0);
    my @latencies;

    for (1 .. $trials) {
        my $t0 = clock_gettime(CLOCK_MONOTONIC);
        my $w  = MT::Worker::spawn('main::w_fiber_isolation', 10);
        my $summary = MT::Worker::join($w);
        my $dt_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;

        my $ok = ($summary eq '8:2:0') ? 1 : 0;
        $ok ? $passed++ : $failed++;
        $total_collateral_drops++ unless $ok;
        push @latencies, $dt_ms;
    }

    my $st = stats_from_samples(\@latencies);
    push @scenarios, {
        id       => 'per_fiber_crash_isolation',
        label    => 'Per-fiber crash isolation',
        metric   => '10-fiber batch',
        trials   => $trials,
        passed   => $passed,
        failed   => $failed,
        %$st,
        detail   => '8/10 fibers finished cleanly, 2 trapped via eval, 0 collateral drops',
    };
}

# ---------------------------------------------------------------------------
# Scenario 5: MT::Checkpoint Atomic Snapshot & Corruption Rejection
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 5 : 20;
    my ($passed, $failed) = (0, 0);
    my @save_samples;
    my @load_samples;
    my @reject_samples;

    for (1 .. $trials) {
        my ($fh, $ckpt_path) = tempfile(UNLINK => 1);
        close $fh;

        my $t0 = clock_gettime(CLOCK_MONOTONIC);
        my $saved = $inv->save_checkpoint($ckpt_path);
        my $save_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;

        my $inv_reloaded = Shop::State::Inventory->new;
        my $t1 = clock_gettime(CLOCK_MONOTONIC);
        my $loaded = $inv_reloaded->load_checkpoint($ckpt_path);
        my $load_ms = (clock_gettime(CLOCK_MONOTONIC) - $t1) * 1000.0;

        # Corrupt one byte inside the payload
        open my $rfh, '+<:raw', $ckpt_path or die "open $ckpt_path: $!\n";
        seek($rfh, 16, 0) or die "seek: $!\n";
        my $byte;
        read($rfh, $byte, 1) == 1 or die "read: $!\n";
        seek($rfh, 16, 0) or die "seek: $!\n";
        print $rfh chr(ord($byte) ^ 0xff);
        close $rfh;

        my $inv_bad = Shop::State::Inventory->new;
        my $t2 = clock_gettime(CLOCK_MONOTONIC);
        eval { $inv_bad->load_checkpoint($ckpt_path) };
        my $err = $@ // '';
        my $reject_ms = (clock_gettime(CLOCK_MONOTONIC) - $t2) * 1000.0;
        unlink $ckpt_path;

        my $ok = ($saved && $loaded == 2
            && $inv_reloaded->get_stock('VT-220') == 100
            && $inv_reloaded->get_stock('AC-MUG') == 50
            && $err =~ /checksum mismatch/i) ? 1 : 0;

        $ok ? $passed++ : $failed++;
        push @save_samples, $save_ms;
        push @load_samples, $load_ms;
        push @reject_samples, $reject_ms;
    }

    my $st = stats_from_samples(\@save_samples);
    my $load_st = stats_from_samples(\@load_samples);
    my $rej_st  = stats_from_samples(\@reject_samples);
    push @scenarios, {
        id           => 'checkpoint_snapshot_corruption',
        label        => 'Checkpoint snapshot & checksum reject',
        metric       => 'atomic save',
        trials       => $trials,
        passed       => $passed,
        failed       => $failed,
        %$st,
        load_p50_ms   => $load_st->{p50_ms},
        reject_p50_ms => $rej_st->{p50_ms},
        detail        => sprintf('load p50 %.3f ms; corrupt byte reject p50 %.3f ms', $load_st->{p50_ms}, $rej_st->{p50_ms}),
    };
}

# ---------------------------------------------------------------------------
# Scenario 6: Hot-Tier Graceful Degradation on KeyDB / DB Outage
# ---------------------------------------------------------------------------
{
    my $trials = $smoke ? 5 : 20;
    my ($passed, $failed) = (0, 0);
    my @latencies;

    my $probe = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
    ) or die "socket: $!\n";
    my $closed_port = $probe->sockport;
    close $probe;

    my $kdb = Shop::Cache::KeyDB->new(host => '127.0.0.1', port => $closed_port, timeout => 1);
    my $kdb_down = eval { $kdb->cmd('PING'); 1 } ? 0 : 1;

    my $db = Shop::DB->new({ driver => 'db2', gateway_url => "http://127.0.0.1:$closed_port", timeout => 1 });
    my $db_down = eval { $db->list_products; 1 } ? 0 : 1;

    my $bus   = Shop::State::EventBus->new;
    my $inbox = $bus->register_session('bench-degraded', { user_fp => 'SHA256:bench' });

    for (1 .. $trials) {
        my $t0 = clock_gettime(CLOCK_MONOTONIC);
        my $hot_err = 0;

        my $cat = eval { $inv->list_catalog };
        $hot_err++ if $@ || !ref($cat) || scalar(@$cat) != 2;

        my ($res_ok, $rem) = eval { $inv->reserve('AC-MUG', 2) };
        $hot_err++ if $@ || !$res_ok || $rem != 48;

        my $after = eval { $inv->release('AC-MUG', 2) };
        $hot_err++ if $@ || !defined($after) || $after != 50;

        my $q = eval {
            Shop::Domain::Pricing::calculate(
                [{ sku => 'AC-MUG', name => 'Enamel Mug', qty => 3, unit_price => '19.9500' }],
                tax_rate => '0.0825',
            );
        };
        $hot_err++ if $@ || !$q || "$q->{total}" ne '72.74';

        my $sent = eval { $bus->broadcast({ type => 'stock_update', sku => 'AC-MUG', stock => 50 }) };
        my $evs  = eval { $bus->poll_inbox($inbox) };
        $hot_err++ if $@ || !defined($sent) || $sent != 1 || !ref($evs) || scalar(@$evs) != 1;

        my $dt_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;
        my $ok = ($kdb_down && $db_down && $hot_err == 0) ? 1 : 0;
        $ok ? $passed++ : $failed++;
        $total_collateral_drops++ unless $ok;
        push @latencies, $dt_ms;
    }

    $bus->unregister_session('bench-degraded');

    my $st = stats_from_samples(\@latencies);
    push @scenarios, {
        id       => 'hot_tier_outage_degradation',
        label    => 'Hot-tier degradation (KeyDB + DB down)',
        metric   => 'hot-tier cycle',
        trials   => $trials,
        passed   => $passed,
        failed   => $failed,
        %$st,
        detail   => "KeyDB/DB closed port; catalog + CAS + Decimal + EventBus 0 errors",
    };
}

# ---------------------------------------------------------------------------
# Summary & output
# ---------------------------------------------------------------------------

my ($scenarios_passed, $trials_total, $trials_passed) = (0, 0, 0);
for my $s (@scenarios) {
    $scenarios_passed++ if $s->{failed} == 0 && $s->{passed} == $s->{trials};
    $trials_total  += $s->{trials};
    $trials_passed += $s->{passed};
}

my $result = {
    suite            => '06_fault_tolerance',
    mode             => $smoke ? 'smoke' : 'full',
    heartbeat_config => {
        heartbeat_ms   => int($hb_cfg->{heartbeat_ms}   // 100),
        heartbeat_miss => int($hb_cfg->{heartbeat_miss} // 3),
    },
    summary          => {
        scenarios_total  => scalar(@scenarios),
        scenarios_passed => $scenarios_passed,
        trials_total     => $trials_total,
        trials_passed    => $trials_passed,
        collateral_drops => $total_collateral_drops,
    },
    scenarios        => \@scenarios,
};

print "\nFault Tolerance & Recovery (" . ($smoke ? 'smoke' : 'full') . ")\n";
printf "%-40s %-18s %8s %9s %9s %s\n",
    'Scenario', 'Metric', 'Pass', 'p50 (ms)', 'p95 (ms)', 'Notes';
print '-' x 118, "\n";
for my $s (@scenarios) {
    printf "%-40s %-18s %3d/%-4d %9.3f %9.3f %s\n",
        $s->{label},
        $s->{metric},
        $s->{passed}, $s->{trials},
        $s->{p50_ms},
        $s->{p95_ms},
        $s->{detail};
}
printf "\nTotal: %d/%d scenarios passed (%d/%d trials, %d collateral drops)\n",
    $scenarios_passed, scalar(@scenarios), $trials_passed, $trials_total, $total_collateral_drops;

if (length $json_path) {
    my $dir = dirname($json_path);
    make_path($dir) if length $dir && !-d $dir;
    open my $fh, '>:encoding(UTF-8)', $json_path or die "Cannot write $json_path: $!\n";
    print $fh JSON::PP->new->utf8(0)->pretty(1)->canonical(1)->encode($result);
    close $fh;
}

exit($scenarios_passed == scalar(@scenarios) ? 0 : 1);
