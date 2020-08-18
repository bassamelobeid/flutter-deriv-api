package BOM::Backoffice::Script::UpdateTradingStrategyData;

use strict;
use warnings;

no indirect;
use Syntax::Keyword::Try;
use List::Util qw(sum shuffle);

use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Chronicle;

use YAML qw(LoadFile);
use Path::Tiny;
use Data::Dumper;
use Fcntl qw(:flock);
use Sys::Info;
use POSIX qw(floor);
use Parallel::ForkManager;

# How many ticks to request at a time
use constant TICK_CHUNK_SIZE => 86400;

# Number of forks to create - as of 2017-01, QA systems have 4 CPUs, backoffice 8,
# so we want to adapt to what's available
use constant WORKERS => floor(Sys::Info->new->device("CPU")->count / 2) || 1;

sub run {
    ++$|;

    open my $unique_lock, '<', $0 or die $!;    ## no critic (RequireBriefOpen)
    die "Another copy of $0 is already running - we expect to run daily, is the script taking more than 24h to complete?"
        unless flock $unique_lock, LOCK_EX | LOCK_NB;

    my $script_start_time = Time::HiRes::time;
    try {
        # Bail out if we take more than a day...
        alarm((24 * 60 * 60) - 10);
        local $SIG{ALRM} = sub { die "Timeout - this script took too long, it needs to complete within 24h" };

        my $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/trading_strategy_datasets.yml');

        # If given a parameter, we'll use that to calculate data for that day - but since we look at the 24h leading up to
        # that day, we need to add 1d first.
        my $target_date = (@ARGV ? Date::Utility->new(shift @ARGV)->plus_time_interval('1d') : Date::Utility->today)->truncate_to_day;

        my $start = $target_date->epoch - 86400;
        my $end   = $target_date->epoch - 1;

        my $now = time;

        my $output_base = '/var/lib/binary/trading_strategy_data/' . Date::Utility->new($start)->date;
        path($output_base)->mkpath;

        # Gather data and create jobs
        my @jobs;
        for my $symbol (@{$config->{underlyings}}) {
            for my $duration (@{$config->{durations}}) {
                for my $bet_type (@{$config->{types}}) {
                    push @jobs, join "\0", $symbol, $duration, $bet_type;
                }
            }
        }

        my $pm = Parallel::ForkManager->new(WORKERS);
        JOB:
        for my $job (@jobs) {
            my $pid        = $pm->start and next JOB;
            my $start_time = Time::HiRes::time;
            my ($symbol, $duration_step, $bet_type) = split "\0", $job;
            print "$$ working on " . ($job =~ s/\0/ /gr) . " from $start..$end\n";
            my ($duration, %duration_options) = split ' ', $duration_step;

            my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
                dbic       => Postgres::FeedDB::read_dbic(),
                underlying => $symbol
            );

            if (
                my @ticks = reverse @{
                    $api->ticks_start_end_with_limit_for_charting({
                            start_time => $start,
                            end_time   => $end,
                            limit      => ($end - $start),
                        })})
            {

                $duration_options{step} //= '1t';
                my ($step_amount, $step_unit) = $duration_options{step} =~ /(\d+)([tmhs])/ or die "unknown step type " . $duration_options{step};
                if ($step_unit eq 'm') {
                    $step_amount *= 60;
                    $step_unit = 's';
                } elsif ($step_unit eq 'h') {
                    $step_amount *= 3600;
                    $step_unit = 's';
                }

                my $key = join '_', $symbol, $duration, $duration_options{step}, $bet_type;
                open my $fh, '>:encoding(UTF-8)', $output_base . '/' . $key . '.csv' or die $!;    ## no critic (RequireBriefOpen)
                $fh->autoflush(1);

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
                            %$args,    ## no critic (ProhibitCommaSeparatedStatements)
                            date_pricing => $now,
                        });
                        if ($contract_expired->is_expired) {
                            my $ask_price = $contract->ask_price;
                            my $value     = $contract_expired->value;
                            $fh->print(join(",", (map { $tick->{$_} } qw(epoch quote)), $ask_price, $value, $contract->theo_price) . "\n");
                        }
                    } catch {
                        warn "Failed to price with parameters " . Dumper($args) . " - $@\n";
                    }
                    if ($step_unit eq 't') {
                        $idx += $step_amount;
                    } elsif ($step_unit eq 's') {
                        ++$idx while $idx <= $#ticks && $step_amount >= $ticks[$idx]->{epoch} - $tick->{epoch};
                    } else {
                        die "Invalid step unit $step_unit";
                    }
                }
            }
            my $elapsed = 1000.0 * (Time::HiRes::time - $start_time);
            printf "%d working on %s took %.2fms\n", $$, ($job =~ s/\0/ /gr), $elapsed;
            $pm->finish;
        }
        $pm->wait_all_children;
    } catch {
        warn "Failed to run - $@";
    }
    alarm(0);
    {
        my $elapsed = Time::HiRes::time - $script_start_time;
        printf "Took %.1f hours to run\n", $elapsed / 3600;
    }
    return;
}

1;
