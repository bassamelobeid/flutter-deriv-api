use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;

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

$client->deposit_virtual_funds;
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

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

subtest 'sell' => sub {
    my $params = {
        language => 'EN',
        token    => 'invalid token'
    };
    $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('The token is invalid.', 'invalid token');

    $params->{token} = $token;

    $client->status->set('disabled', 1, 'test');
    $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'disabled client')
        ->error_message_is('This account is unavailable.', 'account disabled');

    $client->status->clear_disabled;

    #sold  contract should be hold 2 minutes and interval should more than 15
    my $now           = time;
    my $contract_data = Test::BOM::RPC::Contract::prepare_contract(
        start_time   => $now - 60 * 2,
        interval     => '20m',
        tick_epoches => [$now - 1, $now, $now + 1, $now + 2]);
    my $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_data,
        purchase_date       => $now - 60 * 2,
        amount_type         => 'payout',
    });
    $txn->price($txn->contract->ask_price);

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'should no error to buy the contract');

    $params->{source} = 1;
    $params->{args}{sell} = $txn->contract_id;
    my $old_balance = $client->default_account->balance;
    $c->call_ok('sell', $params)->has_no_system_error->has_no_error->result;
    is_deeply([sort keys %{$c->result}], [sort qw(sold_for balance_after transaction_id contract_id stash reference_id)], 'keys is correct');
    my $new_balance = $client->default_account->balance;
    ok($new_balance - $c->result->{balance_after} < 0.000001,           'balance is correct');
    ok($old_balance + $c->result->{sold_for} - $new_balance < 0.000001, 'balance is correct');
};

done_testing();
