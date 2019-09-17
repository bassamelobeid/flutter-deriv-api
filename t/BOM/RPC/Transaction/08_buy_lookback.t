#!perl

use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Format::Util::Numbers qw/formatnumber financialrounding/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;

use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;
use Email::Stuffer::TestLinks;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

$client->deposit_virtual_funds;
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
subtest 'buy' => sub {
    my $params = {
        language => 'EN',
        token    => 'invalid token'
    };
    $params->{token} = $token;

    #So I mock client module to simulate this scenario.
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('new', sub { return undef });
    undef $mocked_client;

    $params->{contract_parameters} = {};

    my (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);

    $params->{source}              = 1;
    $params->{contract_parameters} = {
        "proposal"      => 1,
        "multiplier"    => "1",
        "contract_type" => "LBFLOATCALL",
        "currency"      => "USD",
        "duration"      => "120",
        "duration_unit" => "s",
        "symbol"        => "R_75",
    };

    $params->{args}{price} = 7.59 * 0.5;

    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidPrice', 'Invalid precision for price');

    $params->{args}{price} = financialrounding('price', 'USD', 1.12);
    $params->{contract_parameters}{multiplier} = 1;

    my $old_balance   = $client->default_account->balance;
    my $result        = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            contract_details
            balance_after
            purchase_time
            buy_price
            start_time
            longcode
            shortcode
            payout
            stash
            auth_time
            rpc_time
    ));
    is_deeply([sort keys %$result], [sort @expected_keys], 'result keys is ok');
    my $new_balance = formatnumber('amount', 'USD', $client->default_account->balance);
    is($new_balance, $result->{balance_after}, 'balance is changed');
    ok($old_balance - $new_balance - $result->{buy_price} < 0.0001, 'balance reduced');
    like($result->{shortcode}, qr/LBFLOATCALL_R_75_1_\d{10}_\d{10}/, 'shortcode is correct');
    is($result->{longcode}, 'Win USD 1 times Volatility 75 Index\'s close minus low over the next 2 minutes.', 'longcode is correct');

};

done_testing();
