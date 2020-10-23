use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use BOM::Test::RPC::QueueClient;
use BOM::Config::Redis;

use utf8;

set_absolute_time(Date::Utility->new('2017-11-20 00:00:00')->epoch);

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

my $rpc_ct = BOM::Test::RPC::QueueClient->new();
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
        encode_json_utf8({
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

};

done_testing();
