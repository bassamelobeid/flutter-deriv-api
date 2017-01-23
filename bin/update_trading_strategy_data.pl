use strict;
use warnings;

no indirect;
use Try::Tiny;
use List::Util qw(sum);

use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;
use BOM::Product::ContractFactory qw(produce_contract);

use YAML qw(LoadFile);
use Path::Tiny;
use Data::Dumper;
use Fcntl qw(:flock);

# How many ticks to request at a time
use constant TICK_CHUNK_SIZE => 86400;

++$|;

open my $unique_lock, '<', $0 or die $!;
die "Another copy of $0 is already running - we expect to run daily, is the script taking more than 24h to complete?"
    unless flock $unique_lock, LOCK_EX | LOCK_NB;

try {
    # Bail out if we take more than a day...
    alarm((24 * 60 * 60) - 10);
    $SIG{ALRM} = sub { die "Timeout - this script took too long, it needs to complete within 24h" };

    my $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/trading_strategy_datasets.yml');

    my $target_date = Date::Utility->today->truncate_to_day;

    my $start = $target_date->epoch - 86400;
    my $end   = $target_date->epoch - 1;

    my $now = time;

    my $output_base = '/var/lib/binary/trading_strategy_data/' . Date::Utility->new($start)->date;
    path($output_base)->mkpath;

    for my $symbol (@{$config->{underlyings}}) {
        print "Symbol $symbol\n";
        my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
            db_handle  => Postgres::FeedDB::read_dbh(),
            underlying => $symbol
        );

        my %fh;
        print "Getting ticks from $start to $end...\n";
        my $current = $start;
        BATCH:
        while ($current < $end) {
            my @ticks = reverse @{
                $api->ticks_start_end_with_limit_for_charting({
                        start_time => $current,
                        end_time   => $current + TICK_CHUNK_SIZE,
                        limit      => TICK_CHUNK_SIZE,
                    })}
                or last BATCH;    # if we had no ticks, then we're done for this symbol
            for (@{$config->{durations}}) {
                my ($duration, %duration_options) = split ' ', $_;
                $duration_options{step} //= '1t';
                my ($step_amount, $step_unit) = $duration_options{step} =~ /(\d+)([tmhs])/ or die "unknown step type " . $duration_options{step};
                if ($step_unit eq 'm') {
                    $step_amount *= 60;
                    $step_unit = 's';
                } elsif ($step_unit eq 'h') {
                    $step_amount *= 3600;
                    $step_unit = 's';
                }
                print "Duration $duration\n";
                for my $bet_type (@{$config->{types}}) {
                    print "Bet type $bet_type\n";
                    my $key = join '_', $symbol, $duration, $duration_options{step}, $bet_type;
                    unless (exists $fh{$key}) {
                        open $fh{$key}, '>:encoding(UTF-8)', $output_base . '/' . $key . '.csv' or die $!;
                        $fh{$key}->autoflush(1);
                    }
                    my $idx = 0;
                    while ($idx <= $#ticks) {
                        my $tick = $ticks[$idx];

                        my $args = {
                            underlying   => $symbol,
                            bet_type     => $bet_type,
                            date_start   => $tick->{epoch},
                            date_pricing => $tick->{epoch},
                            duration     => $duration,
                            currency     => 'USD',
                            payout       => 10,
                            barrier      => 'S0P',
                        };
                        try {
                            my $contract         = produce_contract($args);
                            my $contract_expired = produce_contract({
                                %$args,
                                date_pricing => $now,
                            });
                            if ($contract_expired->is_expired) {
                                my $ask_price = $contract->ask_price;
                                my $value     = $contract_expired->value;
                                $fh{$key}->print(join(",", (map $tick->{$_}, qw(epoch quote)), $ask_price, $value, $contract->theo_price) . "\n");
                            }
                        }
                        catch {
                            warn "Failed to price with parameters " . Dumper($args) . " - $_\n";
                        };
                        if ($step_unit eq 't') {
                            $idx += $step_amount;
                        } elsif ($step_unit eq 's') {
                            ++$idx while $idx <= $#ticks && $step_amount >= $ticks[$idx]->{epoch} - $tick->{epoch};
                        } else {
                            die "Invalid step unit $step_unit";
                        }
                    }
                }
            }
            $current = 1 + $ticks[-1]{epoch};
        }
    }
}
catch {
    warn "Failed to run - $_";
};
alarm(0);
