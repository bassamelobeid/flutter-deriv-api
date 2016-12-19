use strict;
use warnings;

use List::Util qw(sum);

use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;
use BOM::Product::ContractFactory qw(produce_contract);

use YAML qw(LoadFile);
use Path::Tiny;

++$|;

my $config = LoadFile('config/files/trading_strategy_datasets.yml');

my $start = $config->{start_epoch};
my $end = $config->{end_epoch};
my $now = time;


my $output_base = '/var/lib/binary/trading_strategy_data';
$_->remove for path($output_base)->children;

for my $symbol (qw(frxUSDJPY R_100)) {
    print "Symbol $symbol\n";
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
        db_handle => Postgres::FeedDB::read_dbh,
        underlying => $symbol 
    );

    print "Getting ticks from $start to $end...\n";
    my @ticks = reverse @{$api->ticks_start_end_with_limit_for_charting({
            start_time => $start,
            end_time => $end,
            limit => 100,
    })};
die 'no ticks' unless @ticks;
    for my $duration (@{$config->{durations}}) {
        print "Duration $duration\n";
        for my $bet_type (qw(PUT CALL)) {
            print "Bet type $bet_type\n";
            open my $fh, '>:encoding(UTF-8)', $output_base . '/' . join '_', $symbol, $duration, $bet_type or die $!;
            $fh->autoflush(1);
            for my $tick (@ticks) {
                my $args = {
                    underlying   => $symbol,
                    bet_type     => 'CALL',
                    date_start   => $tick->{epoch},
                    date_pricing => $tick->{epoch},
                    duration     => '5t',
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
                    $fh->print( join(",", (map $tick->{$_}, qw(epoch quote)), $ask_price, $value) . "\n" );
                }
            }

        }
    }
}
