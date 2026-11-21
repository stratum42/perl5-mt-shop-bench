#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);

BEGIN {
    my $repo_root = abs_path("$FindBin::Bin/..");
    my $perl5_mt_root = $ENV{PERL5_MT_ROOT}
        || (-d "$repo_root/../perl5-mt" ? abs_path("$repo_root/../perl5-mt") : "$repo_root/../perl5-mt");
    my $shop_root = $ENV{SHOP_ROOT}
        || (-d "$repo_root/../perl5-mt-shop" ? abs_path("$repo_root/../perl5-mt-shop") : "$repo_root/../perl5-mt-shop");

    # Re-exec under perl5-mt if MT::Decimal is not available in current Perl
    if (!eval { require MT::Decimal; 1 }) {
        my $mt_perl = "$perl5_mt_root/perl";
        my $mt_lib  = "$perl5_mt_root/lib";
        if (-x $mt_perl && !$ENV{_SHOP_BENCH_REEXEC}) {
            local $ENV{_SHOP_BENCH_REEXEC} = 1;
            exec($mt_perl, "-I$mt_lib", $0, @ARGV);
        }
        die "MT::Decimal not available and perl5-mt not found at $mt_perl (set PERL5_MT_ROOT)\n";
    }

    for my $dir (
        "$shop_root/lib",
        "$shop_root/xs/Shop-SSH-Crypto/blib/lib",
        "$shop_root/xs/Shop-SSH-Crypto/blib/arch",
    ) {
        unshift @INC, $dir if -d $dir && !grep { $_ eq $dir } @INC;
    }
}

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Time::HiRes qw(time);

use Shop::DB;
use Shop::Cache::KeyDB;

my $repo_root = abs_path("$FindBin::Bin/..");
my $shop_root = $ENV{SHOP_ROOT}
    || (-d "$repo_root/../perl5-mt-shop" ? abs_path("$repo_root/../perl5-mt-shop") : "$repo_root/../perl5-mt-shop");
my $db2_url    = $ENV{DB2_GATEWAY_URL}      // 'http://127.0.0.1:50050';
my $ifx_url    = $ENV{INFORMIX_GATEWAY_URL} // 'http://127.0.0.1:50051';
my $keydb_host = $ENV{KEYDB_HOST}           // '127.0.0.1';
my $keydb_port = defined $ENV{KEYDB_PORT} ? int($ENV{KEYDB_PORT}) : 6380;

my $opt_smoke = 0;
my $opt_json  = '';
my $opt_iters = 0;

GetOptions(
    'smoke!'  => \$opt_smoke,
    'json=s'  => \$opt_json,
    'iters=i' => \$opt_iters,
) or die "Usage: $0 [--smoke] [--json path] [--iters N]\n";

my $sql_iters_sqlite = $opt_iters || ($opt_smoke ? 20  : 80);
my $sql_iters_remote = $opt_iters || ($opt_smoke ? 20  : 100);
my $keydb_iters      = $opt_iters || ($opt_smoke ? 100 : 500);
my $pipe_batch_pairs = 20; # 20 SET + 20 GET = 40 commands per pipeline batch

sub percentile {
    my ($sorted, $p) = @_;
    return 0.0 unless @$sorted;
    my $idx = int(($p / 100.0) * @$sorted);
    $idx = $#$sorted if $idx > $#$sorted;
    $idx = 0 if $idx < 0;
    return $sorted->[$idx];
}

sub bench_op {
    my ($iters, $warmup, $fn) = @_;
    for (1 .. $warmup) {
        $fn->();
    }
    my @lats;
    my $t_all0 = time();
    for (1 .. $iters) {
        my $t0 = time();
        $fn->();
        push @lats, (time() - $t0) * 1000.0;
    }
    my $elapsed = time() - $t_all0;
    my @sorted  = sort { $a <=> $b } @lats;
    my $ops_sec = $elapsed > 0 ? ($iters / $elapsed) : 0;
    return {
        iters    => $iters,
        elapsed  => sprintf('%.4f', $elapsed) + 0,
        ops_sec  => sprintf('%.2f', $ops_sec) + 0,
        p50_ms   => sprintf('%.3f', percentile(\@sorted, 50)) + 0,
        p95_ms   => sprintf('%.3f', percentile(\@sorted, 95)) + 0,
    };
}

sub bench_sql_backend {
    my ($name, $label, $db, $iters, $note) = @_;
    my $prods = eval { $db->list_products() };
    if ($@ || !$prods || !@$prods) {
        return {
            backend   => $name,
            label     => $label,
            available => JSON::PP::false,
            note      => "Failed to query products: " . ($@ || 'empty catalog'),
            ops       => {},
        };
    }

    # Pick product with highest stock for decrement test
    my ($target) = sort { int($b->{stock} // 0) <=> int($a->{stock} // 0) } @$prods;
    my $sku        = $target->{sku};
    my $orig_stock = int($target->{stock} // 0);

    my %ops;

    # 1. list_products
    $ops{list_products} = bench_op($iters, 3, sub {
        my $r = $db->list_products();
        die "list_products returned empty" unless $r && @$r;
    });

    # 2. decrement_product_stock (always restore original stock afterward)
    if ($orig_stock >= 2) {
        my $cur_stock = $orig_stock;
        my $dec_err;
        eval {
            # Warmup 2 ops then restore
            for (1 .. 2) {
                $db->decrement_product_stock($sku, 1);
                $cur_stock--;
                if ($cur_stock <= 1) {
                    $db->update_product_stock($sku, $orig_stock);
                    $cur_stock = $orig_stock;
                }
            }
            $db->update_product_stock($sku, $orig_stock);
            $cur_stock = $orig_stock;

            my @lats;
            my $total_time = 0.0;
            for (1 .. $iters) {
                if ($cur_stock <= 1) {
                    $db->update_product_stock($sku, $orig_stock);
                    $cur_stock = $orig_stock;
                }
                my $t0 = time();
                my $res = $db->decrement_product_stock($sku, 1);
                my $dt = time() - $t0;
                die "decrement_product_stock returned undef for $sku" unless $res;
                $total_time += $dt;
                push @lats, $dt * 1000.0;
                $cur_stock--;
            }
            my @sorted = sort { $a <=> $b } @lats;
            $ops{decrement_product_stock} = {
                iters   => $iters,
                elapsed => sprintf('%.4f', $total_time) + 0,
                ops_sec => sprintf('%.2f', $total_time > 0 ? ($iters / $total_time) : 0) + 0,
                p50_ms  => sprintf('%.3f', percentile(\@sorted, 50)) + 0,
                p95_ms  => sprintf('%.3f', percentile(\@sorted, 95)) + 0,
                sku     => $sku,
                restored_stock => $orig_stock,
            };
        };
        $dec_err = $@;
        # Always restore exact original stock
        eval { $db->update_product_stock($sku, $orig_stock); };
        die $dec_err if $dec_err;
    }

    # 3. category_olap
    $ops{category_olap} = bench_op($iters, 3, sub {
        my $r = $db->category_olap();
        die "category_olap failed" unless ref($r) eq 'ARRAY';
    });

    # 4. tax_nexus_report
    $ops{tax_nexus_report} = bench_op($iters, 3, sub {
        my $r = $db->tax_nexus_report();
        die "tax_nexus_report failed" unless ref($r) eq 'ARRAY';
    });

    return {
        backend   => $name,
        label     => $label,
        available => JSON::PP::true,
        note      => $note,
        features  => $db->db2_features(),
        ops       => \%ops,
    };
}

my $tmpdir = tempdir(CLEANUP => 1);
my @backends;

# 1. SQLite (fresh temp DB)
{
    my $sqlite_db = Shop::DB->new({
        driver      => 'sqlite',
        sqlite_path => "$tmpdir/bench_sqlite.db",
    });
    $sqlite_db->init_schema(
        "$shop_root/sql/schema_sqlite.sql",
        "$shop_root/sql/seed.sql",
    );
    push @backends, bench_sql_backend(
        'sqlite',
        'SQLite 3 (CLI subprocess)',
        $sqlite_db,
        $sql_iters_sqlite,
        'Spawns sqlite3 CLI per call (zero-XS thread-safe adapter)',
    );
}

# 2. IBM Db2 12.1 SP-ONLY
{
    my $db2 = Shop::DB->new({
        driver      => 'db2',
        gateway_url => $db2_url,
        timeout     => 5,
    });
    my $ok = eval { $db2->health() } ? 1 : 0;
    if ($ok) {
        push @backends, bench_sql_backend(
            'db2',
            'IBM Db2 12.1 (SP-ONLY HTTP gateway)',
            $db2,
            $sql_iters_remote,
            "Live Docker gateway at $db2_url (DB2_SP_ONLY=1, HTTP keep-alive)",
        );
    } else {
        push @backends, {
            backend   => 'db2',
            label     => 'IBM Db2 12.1 (SP-ONLY HTTP gateway)',
            available => JSON::PP::false,
            note      => "Skipped: Db2 gateway not reachable at $db2_url",
            ops       => {},
        };
    }
}

# 3. IBM Informix 15.0 SP-ONLY
{
    my $ifx = Shop::DB->new({
        driver               => 'informix',
        informix_gateway_url => $ifx_url,
        timeout              => 5,
    });
    my $ok = eval { $ifx->health() } ? 1 : 0;
    if ($ok) {
        push @backends, bench_sql_backend(
            'informix',
            'IBM Informix 15.0 (SP-ONLY HTTP gateway)',
            $ifx,
            $sql_iters_remote,
            "Live Docker gateway at $ifx_url (INFORMIX_SP_ONLY=1, HTTP keep-alive)",
        );
    } else {
        push @backends, {
            backend   => 'informix',
            label     => 'IBM Informix 15.0 (SP-ONLY HTTP gateway)',
            available => JSON::PP::false,
            note      => "Skipped: Informix gateway not reachable at $ifx_url",
            ops       => {},
        };
    }
}

# 4. KeyDB
my $keydb_result;
{
    my $kdb = Shop::Cache::KeyDB->new(
        host    => $keydb_host,
        port    => $keydb_port,
        timeout => 2,
        prefix  => 'bench:',
    );
    my $ok = eval { $kdb->ping() } ? 1 : 0;
    if ($ok) {
        my $ver = '';
        eval {
            my $info = $kdb->cmd('INFO', 'server');
            if (defined $info && $info =~ /redis_version:([^\r\n]+)/) {
                $ver = $1;
            }
            if (defined $info && $info =~ /keydb_version:([^\r\n]+)/) {
                $ver = "KeyDB $1";
            }
        };

        my @pipe_cmds;
        for my $i (1 .. $pipe_batch_pairs) {
            push @pipe_cmds, ['SET', "bench:p:$i", "val-$i", 'EX', 60];
        }
        for my $i (1 .. $pipe_batch_pairs) {
            push @pipe_cmds, ['GET', "bench:p:$i"];
        }
        my $cmds_per_batch = scalar(@pipe_cmds);

        my $pipe_res = bench_op($keydb_iters, 5, sub {
            my $r = $kdb->pipeline(\@pipe_cmds);
            die "pipeline failed" unless $r && @$r == $cmds_per_batch;
        });
        $pipe_res->{cmds_per_batch} = $cmds_per_batch;
        $pipe_res->{cmds_sec}       = sprintf('%.2f', $pipe_res->{ops_sec} * $cmds_per_batch) + 0;

        # Cleanup pipeline keys
        eval { $kdb->del(map { "p:$_" } 1 .. $pipe_batch_pairs); };

        my $lua_res = bench_op($keydb_iters, 5, sub {
            my $r = $kdb->reserve_cart_lease('bench_fp', 'BENCH-SKU-1', 1, 60);
            die "reserve_cart_lease failed" unless defined $r && $r > 0;
        });
        eval { $kdb->clear_cart('bench_fp'); };
        $kdb->close();

        $keydb_result = {
            backend   => 'keydb',
            label     => "KeyDB ($keydb_host:$keydb_port)",
            available => JSON::PP::true,
            version   => $ver,
            note      => "Live RESP2 TCP instance on $keydb_host:$keydb_port",
            ops       => {
                pipeline_set_get       => $pipe_res,
                lua_reserve_cart_lease => $lua_res,
            },
        };
    } else {
        $keydb_result = {
            backend   => 'keydb',
            label     => "KeyDB ($keydb_host:$keydb_port)",
            available => JSON::PP::false,
            version   => '',
            note      => "Skipped: KeyDB not reachable at $keydb_host:$keydb_port",
            ops       => {},
        };
    }
}

# ---------------------------------------------------------------------------
# Print stdout summary
# ---------------------------------------------------------------------------
print "05_databases_compare (mode=" . ($opt_smoke ? 'smoke' : 'full') . ")\n";
printf "%-12s %-25s %10s %10s %10s\n",
    'Backend', 'Operation', 'Ops/s', 'p50(ms)', 'p95(ms)';
printf "%-12s %-25s %10s %10s %10s\n",
    '-' x 12, '-' x 25, '-' x 10, '-' x 10, '-' x 10;

my @sql_ops = qw(list_products decrement_product_stock category_olap tax_nexus_report);
for my $b (@backends) {
    if (!$b->{available}) {
        printf "%-12s %-25s %s\n", $b->{backend}, '(skipped)', $b->{note};
        next;
    }
    for my $op (@sql_ops) {
        my $r = $b->{ops}{$op} or next;
        printf "%-12s %-25s %10.1f %10.2f %10.2f\n",
            $b->{backend}, $op, $r->{ops_sec}, $r->{p50_ms}, $r->{p95_ms};
    }
}

if (!$keydb_result->{available}) {
    printf "%-12s %-25s %s\n", 'keydb', '(skipped)', $keydb_result->{note};
} else {
    my $pr = $keydb_result->{ops}{pipeline_set_get};
    printf "%-12s %-25s %10.1f %10.2f %10.2f  (%.0f cmds/s, %d cmds/batch)\n",
        'keydb', 'pipeline_set_get', $pr->{ops_sec}, $pr->{p50_ms}, $pr->{p95_ms},
        $pr->{cmds_sec}, $pr->{cmds_per_batch};
    my $lr = $keydb_result->{ops}{lua_reserve_cart_lease};
    printf "%-12s %-25s %10.1f %10.2f %10.2f\n",
        'keydb', 'lua_reserve_cart_lease', $lr->{ops_sec}, $lr->{p50_ms}, $lr->{p95_ms};
}

my $payload = {
    benchmark    => '05_databases_compare',
    mode         => $opt_smoke ? 'smoke' : 'full',
    sql_backends => \@backends,
    keydb        => $keydb_result,
};

if (length $opt_json) {
    my $dir = dirname($opt_json);
    make_path($dir) if length $dir && !-d $dir;
    open my $jfh, '>', $opt_json or die "Cannot write $opt_json: $!\n";
    print $jfh JSON::PP->new->utf8->pretty->canonical->encode($payload);
    close $jfh;
}

exit 0;
