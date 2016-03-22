use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::Product;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email
)->token;

$client->deposit_virtual_funds;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

subtest 'sell' => sub {
    my $params = {
        language => 'ZH_CN',
        token    => 'invalid token'
    };
    $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('令牌无效。', 'invalid token');

    $params->{token} = $token;

    $client->set_status('disabled', 1, 'test');
    $client->save;
    $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'disabled client')
        ->error_message_is('此账户不可用。', 'account disabled');

    $client->clr_status('disabled');
    $client->save;

    #sold  contract should be hold 2 minutes and interval should more than 15
    my $now      = time;
    my $contract = BOM::Test::Data::Utility::Product::create_contract(
        start_time   => $now - 60 * 2,
        interval     => '20m',
        tick_epoches => [$now - 1, $now, $now + 1, $now + 2]);
    ok($contract);

    my $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now - 60 * 2,
    });

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'should no error to buy the contract');

    $params->{source} = 1;
    $params->{args}{sell} = $txn->contract_id;
    my $old_balance = $client->default_account->load->balance;
    $c->call_ok('sell', $params)->has_no_system_error->has_no_error->result;
    is_deeply([sort keys %{$c->result}], [sort qw(sold_for balance_after transaction_id contract_id)], 'keys is correct');
    my $new_balance = $client->default_account->load->balance;
    ok($new_balance - $c->result->{balance_after} < 0.000001,           'balance is correct');
    ok($old_balance + $c->result->{sold_for} - $new_balance < 0.000001, 'balance is correct');
};

done_testing();
