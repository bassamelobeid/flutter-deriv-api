use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;

use Postgres::FeedDB;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Backoffice::Quant::FeedConfiguration  qw(get_existing_drift_switch_spread get_maximum_commission get_maximum_perf save_drift_switch_spread);

my $now       = Date::Utility->new('01-01-2023')->db_timestamp;
my $mock_tick = Test::MockModule->new('BOM::Backoffice::Quant::FeedConfiguration');
$mock_tick->mock(
    'current_tick',
    sub {
        my $symbol = shift;
        return 10000 if $symbol eq 'DSI10';
        return 20000 if $symbol eq 'DSI20';
        return 30000 if $symbol eq 'DSI30';
    });

subtest 'DB functions' => sub {
    my $query = q{ SELECT feed.set_underlying_spread_configuration(?, ?, ?, ?, ?) };

    my $feeddb = Postgres::FeedDB::write_dbic()->dbh;
    $feeddb->do($query, undef, $now, 'DSI10', 69, 420, 0.3142);

    my $result = get_existing_drift_switch_spread();

    is $result->{'DSI10'}->{commission_0}, 69,     'Commissio_0 matches expectation';
    is $result->{'DSI10'}->{commission_1}, 420,    'Commissio_1 matches expectation';
    is $result->{'DSI10'}->{perf},         0.3142, 'Spread matches expectation';
};

subtest 'Product Quants Limits' => sub {
    my $max_comm = get_maximum_commission();
    is $max_comm->{DSI10}, 1270, 'Matches expectation based on product quants specifiction';
    is $max_comm->{DSI20}, 3048, 'Matches expectation based on product quants specifiction';
    is $max_comm->{DSI30}, 4001, 'Matches expectation based on product quants specifiction';
    is get_maximum_perf,   2,    'Matches expectation based on product quants specifiction';
};

done_testing;
1;
