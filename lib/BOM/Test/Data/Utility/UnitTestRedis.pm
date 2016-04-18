package BOM::Test::Data::Utility::UnitTestRedis;

use strict;
use warnings;

use BOM::Market::Underlying;
use BOM::Market::AggTicks;
use Path::Tiny;
use Net::EmptyPort qw( check_port );
use Time::HiRes qw( usleep );

use base qw( Exporter );
our @EXPORT_OK = qw(initialize_realtime_ticks_db update_combined_realtime);

BEGIN {
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{BOM_CACHE_SERVER} = '127.0.0.1:6385';

    # Cache::RedisDB uses environment REDIS_CACHE_SERVER to connect redis server
    $ENV{REDIS_CACHE_SERVER} = '127.0.0.1:6385';
}

sub start_redis_if_not_running {
    my $redis_port = (split /:/, $ENV{BOM_CACHE_SERVER})[-1];
    return check_port($redis_port) || restart_redis_server();
}

sub restart_redis_server {
    my $config = <<'EOC';
daemonize yes
port 6385
bind 127.0.0.1
timeout 0
loglevel notice
logfile /tmp/redis_bom_test.log
databases 2
dbfilename dump_bom_test.rdb
dir /tmp
pidfile /tmp/test_redis.pid
EOC

    path("/tmp/redis.cfg")->spew($config);

    my $pfile = path('/tmp/test_redis.pid');
    if ($pfile->exists) {
        chomp(my $pid = $pfile->slurp);
        if (kill(0, $pid)) {
            my $cmd = path("/proc/$pid/cmdline")->slurp;
            kill 9, $pid if $cmd =~ /redis/;
            wait_till_exit($pid, 3);
        }
    }

    unlink '/tmp/dump_bom_test.rdb';

    my $pid = fork;
    if (not defined $pid) {
        die 'Could not fork process to start redis-server: ' . $!;
    } elsif ($pid == 0) {
        exec "redis-server", "/tmp/redis.cfg";
        die "Oops... Couldn't start redis-server: $!";
    }
    waitpid $pid, 0;
    Net::EmptyPort::wait_port(6385, 10);
    unlink '/tmp/redis.cfg';

    return;
}

sub wait_till_exit {
    my ($pid, $timeout) = @_;
    while ($timeout and kill ZERO => $pid) {
        usleep 1e5;
    }
    return;
}

BEGIN {
    ## auto check if redis is running
    start_redis_if_not_running();
}

sub initialize_realtime_ticks_db {
    my %ticks = %{get_test_realtime_ticks()};
    for my $symbol (keys %ticks) {
        my $ul = BOM::Market::Underlying->new($symbol);
        $ticks{$symbol}->{epoch} = time + 600;
        $ul->set_combined_realtime($ticks{$symbol});
    }

    return;
}

sub get_test_realtime_ticks {
    my $test_realtime_ticks = {
        'FCHI' => {
            'quote' => '3563.07',
            'epoch' => '1278660480',
        },
        'frxAUDJPY' => {
            'quote' => '76.984',
            'epoch' => '1284009381',
        },
        'frxUSDJPY' => {
            'quote' => '97.14',
            'epoch' => '1243238400',
        },
        'frxBROUSD' => {
            'quote' => '79.281',
            'epoch' => '1269486429',
        },
        'RDBULL' => {
            'high'  => '1073.6541',
            'open'  => '1000',
            'quote' => '953.8053',
            'epoch' => '1268102279',
            'ticks' => '1320',
            'low'   => '951.4045',
        },
        'R_75' => {
            'quote' => '953.8053',
            'epoch' => '1268102279',
        },
        'SPC' => {
            'quote' => '1144.98',
            'epoch' => '1262970000',
        },
        'SPGSCN' => {
            'quote' => '1144.98',
            'epoch' => '1262970000',
        },
        'GDAXI' => {
            'quote' => '7600',
            'epoch' => '1205928000',
        },
        'N225' => {
            'quote' => '9580.6',
            'epoch' => '1278911311',
        },
        'frxAUDGBP' => {
            'quote' => '0.50181',
            'epoch' => '1250586817',
        },
        'FTSE' => {
            'quote' => '7000',
            'epoch' => '1205928000',
        },
        'R_25' => {
            'quote' => '7600',
            'epoch' => '1231516800',
        },
        'SSMI' => {
            'quote' => '6169.87',
            'epoch' => '1278666500',
        },
        'frxXAUUSD' => {
            'quote' => '111',
            'epoch' => '1205928000',
        },
        'R_100' => {
            'quote' => '65258.19',
            'epoch' => '1234515472',
        },
        'N150' => {
            'quote' => '1397.33',
            'epoch' => '1278660480',
        },
        'JCI' => {
            'quote' => '2967.563',
            'epoch' => '1278910672',
        },
        'BFX' => {
            'quote' => '2467.12',
            'epoch' => '1278660480',
        },
        'HSI' => {
            'quote' => '7000',
            'epoch' => '944031764',
        },
        'IXIC' => {
            'quote' => '2135.46',
            'epoch' => '1265384681',
        },
        'frxAUDUSD' => {
            'quote' => '0.82534',
            'epoch' => '1250586863',
        },
        'frxEURJPY' => {
            'quote' => '134.224',
            'epoch' => '1242022170',
        },
        'AS51' => {
            'quote' => '4404.2',
            'epoch' => '1278911285',
        },
        'frxEURUSD' => {
            'quote' => '1.45762',
            'epoch' => '1252560435',
        },
        'FTSEMIB' => {
            'quote' => '20382.4',
            'epoch' => '1278666501',
        },
        'frxEURGBP' => {
            'quote' => '0.88062',
            'epoch' => '1252560730',
        },
        'IBEX35' => {
            'quote' => '10069.3',
            'epoch' => '1278666506',
        },
        'N100' => {
            'quote' => '643.81',
            'epoch' => '1278660480',
        },
        'UKBARC' => {
            'quote' => '300.35',
            'epoch' => '1278666501',
        },
        'frxGBPUSD' => {
            'quote' => '2',
            'epoch' => '1205928000',
        },
        'DJI' => {
            'quote' => '7600',
            'epoch' => '1231516800',
        },
        'R_50' => {
            'quote' => '963.3054',
            'epoch' => '1245738403',
        },
    };

    return $test_realtime_ticks;
}

##################################################################################################
# update_combined_realtime(
#   datetime => $bom_date,            # tick time
#   underlying => $model_underlying,  # underlying
#   tick => {                         # tick data
#       open  => $open,
#       quote => $last_price,         # latest price
#       ticks => $numticks,           # number of ticks
#   },
#)
##################################################################################################
sub update_combined_realtime {
    my %args = @_;
    $args{underlying} = BOM::Market::Underlying->new($args{underlying_symbol});
    my $underlying_symbol = $args{underlying}->symbol;
    my $unixtime          = $args{datetime}->epoch;
    my $marketitem        = $args{underlying}->market->name;
    my $tick              = $args{tick};

    $tick->{epoch} = $unixtime;
    my $res = $args{underlying}->set_combined_realtime($tick);

    if (scalar grep { $args{underlying}->symbol eq $_ } (BOM::Market::UnderlyingDB->instance->symbols_for_intraday_fx)) {
        BOM::Market::AggTicks->new->add({
            symbol => $args{underlying}->symbol,
            epoch  => $tick->{epoch},
            quote  => $tick->{quote},
        });
    }
    return 1;
}

1;
