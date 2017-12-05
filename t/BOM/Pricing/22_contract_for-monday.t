use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use JSON::MaybeXS;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use BOM::Test::RPC::Client;
use BOM::Product::Contract::PredefinedParameters qw(update_predefined_highlow);

use utf8;

my $mock = Test::MockModule->new('BOM::Product::Contract::PredefinedParameters');
$mock->mock('_get_predefined_highlow', sub { (100, 90) });
$mock->mock('update_predefined_highlow', sub { 1 });

set_absolute_time(Date::Utility->new('2017-11-20 00:00:00')->epoch);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new->minus_time_interval('100d')->epoch,
});

my ($t, $rpc_ct);
my $method = 'contracts_for';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {
            contracts_for => 'R_50',
        },
    });

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
set_absolute_time(Date::Utility->new('2017-11-20 00:00:00')->epoch);

subtest "Request $method" => sub {
    my (%got_landing_company, $result);

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}], [sort qw/ available close open hit_count spot feed_license /], 'It should return contracts_for object';
    ok @{$result->{available}}, 'It should return available contracts';
    ok !grep { $_->{contract_type} =~ /^(EXPIRYMISS|EXPIRYRANGE)E$/ } @{$result->{available}};

    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxUSDJPY', Date::Utility->new);

    $params[1]{args}{product_type}  = 'multi_barrier';
    $params[1]{args}{contracts_for} = 'frxUSDJPY';
    $params[1]{args}{landing_company} = 'japan';

    # mock distributor quote
    my $redis = BOM::Platform::RedisReplicated::redis_write();
    $redis->set(
        'Distributor::QUOTE::frxUSDJPY',
        encode_json({
                quote => 500,
            }));

    my $mock_feeddb = Test::MockModule->new('Postgres::FeedDB::Spot');
    $mock_feeddb->mock(
        'tick_at',
        sub {
            print "tick...\n";
            Postgres::FeedDB::Spot::Tick->new({
                symbol => 'frxUSDJPY',
                epoch  => 1340871449,
                bid    => 2.01,
                ask    => 2.03,
                quote  => 2.02,
            });
        });

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply [sort keys %{$result}],
        [sort qw/ available close open hit_count spot feed_license /],
        'It should return contracts_for object for japan region';
    ok @{$result->{available}}, 'It should return available contracts only for japan region';
    ok !grep { $_->{contract_type} =~ /^(CALL|PUTE|EXPIRYMISSE|EXPIRYRANGE)$/ } @{$result->{available}};

    is $result->{available}->[0]->{available_barriers}->[2]->[0], '500.000';

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
        ->error_message_is('The symbol is invalid.', 'It should return error if symbol does not exist');
};

done_testing();
