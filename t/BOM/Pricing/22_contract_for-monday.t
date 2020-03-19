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
use BOM::Config::Redis;

use utf8;

my $mock = Test::MockModule->new('BOM::Product::Contract::PredefinedParameters');
$mock->mock('_get_predefined_highlow', sub { (100, 90) });

set_absolute_time(Date::Utility->new('2017-11-20 00:00:00')->epoch);
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

$t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
set_absolute_time(Date::Utility->new('2017-11-20 00:15:00')->epoch);

subtest "Request $method" => sub {
    my (%got_landing_company, $result);

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;

    is_deeply [sort keys %{$result}], [sort qw/ available close open hit_count spot feed_license stash/], 'It should return contracts_for object';
    ok @{$result->{available}}, 'It should return available contracts';
    ok !grep { $_->{contract_type} =~ /^(EXPIRYMISS|EXPIRYRANGE)E$/ } @{$result->{available}};

    # mock distributor quote
    my $redis = BOM::Config::Redis::redis_replicated_write();
    $redis->set(
        'Distributor::QUOTE::frxUSDJPY',
        encode_json({
                quote => 500,
                epoch => 1340871449
            }));
    my $mock_feeddb = Test::MockModule->new('Postgres::FeedDB::Spot');
    $mock_feeddb->mock(
        'tick_at',
        sub {
            print "tick...\n";
            Postgres::FeedDB::Spot::Tick->new({
                symbol => 'frxUSDJPY',
                epoch  => 1340871448,
                bid    => 2.01,
                ask    => 2.03,
                quote  => 2.02,
            });
        });

    BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_parameters_for('frxUSDJPY', Date::Utility->new);

    $params[1]{args}{product_type}    = 'multi_barrier';
    $params[1]{args}{contracts_for}   = 'frxUSDJPY';
    $params[1]{args}{landing_company} = 'svg';

    $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    is_deeply [sort keys %{$result}],
        [sort qw/ available close open hit_count spot feed_license stash/],
        'It should return contracts_for object for svg';
    ok @{$result->{available}}, 'It should return available contracts only for svg';
    ok !grep { $_->{contract_type} =~ /^(CALL|PUTE|EXPIRYMISSE|EXPIRYRANGE)$/ } @{$result->{available}};

    is $result->{available}->[0]->{available_barriers}->[3], '500.000';

    $params[1]{args}{contracts_for} = 'invalid symbol';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if symbol does not exist')
        ->error_message_is('This contract is not offered in your country.', 'It should return error if symbol does not exist');
};

done_testing();
