use strict;
use warnings;

use List::Util qw(sum);

use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;
use BOM::Product::ContractFactory qw(produce_contract);

use YAML qw(LoadFile);
use Path::Tiny;

# How many ticks to request at a time
use constant TICK_CHUNK_SIZE => 1000;

++$|;

my $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/trading_strategy_datasets.yml');

my $target_date = Date::Utility->today->truncate_to_day;

my $start = $target_date->epoch - 86400;
my $end =   $target_date->epoch - 1;

my $now = time;

my $output_base = '/var/lib/binary/trading_strategy_data/' . $target_date->date;
path($output_base)->mkpath;

for my $symbol (@{$config->{underlyings}}) {
    print "Symbol $symbol\n";
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
        db_handle => Postgres::FeedDB::read_dbh,
        underlying => $symbol 
    );

    my %fh;
    print "Getting ticks from $start to $end...\n";
    my $current = $start;
    while($current < $end) {
        my @ticks = reverse @{$api->ticks_start_end_with_limit_for_charting({
            start_time => $current,
            end_time => $current + TICK_CHUNK_SIZE,
            limit => TICK_CHUNK_SIZE,
        })};
        for my $duration (@{$config->{durations}}) {
            print "Duration $duration\n";
            for my $bet_type (@{$config->{types}}) {
                print "Bet type $bet_type\n";
                my $key = join '_', $symbol, $duration, $bet_type;
                unless(exists $fh{$key}) {
                    open $fh{$key}, '>:encoding(UTF-8)', $output_base . '/' . $key . '.csv' or die $!;
                    $fh{$key}->autoflush(1);
                }
                for my $tick (@ticks) {
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
                    my $contract = produce_contract($args);
                    my $contract_expired = produce_contract({
                        %$args,
                        date_pricing => $now,
                    });
                    if($contract_expired->is_expired) {
                        my $ask_price = $contract->ask_price;
                        my $value = $contract_expired->value;
                        $fh{$key}->print( join(",", (map $tick->{$_}, qw(epoch quote)), $ask_price, $value) . "\n" );
                    }
                }
            }
        }
	$current = 1 + $ticks[-1]{epoch};
    }
}
