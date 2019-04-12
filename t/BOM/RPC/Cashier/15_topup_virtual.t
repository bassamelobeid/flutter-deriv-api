use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Email::Stuffer::TestLinks;

use utf8;

# init test data
my $email       = 'raunak@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->set_default_account('USD');
$test_client->save;
my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->set_default_account('USD');
$test_client_vr->save;
my $test_loginid = $test_client->loginid;

my $oauth = BOM::Database::Model::OAuth->new;
my ($token)    = $oauth->store_access_token_only(1, $test_loginid);
my ($token_vr) = $oauth->store_access_token_only(1, $test_client_vr->loginid);

my $account     = $test_client_vr->default_account;
my $old_balance = $account->balance;

sub expected_result {
    return {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        currency => 'USD',
        amount   => shift
    };
}

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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

my $now        = Date::Utility->new('2005-09-21 06:46:00');
my $underlying = create_underlying('R_50');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now,
    });

my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 99,
    underlying => 'R_50',
    quote      => 76.5996,
    bid        => 76.6010,
    ask        => 76.2030,
});

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
        quote      => 76.5996,
        bid        => 76.7010,
        ask        => 76.3030,

});

my $tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch + 100,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
});

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
my $amount = 10000;
# start test topup_virtual
my $method = 'topup_virtual';
my $params = {
    language => 'EN',
    token    => '12345'
};

$c->call_ok($method, $params)->has_error->error_code_is('InvalidToken')->error_message_is('The token is invalid.', 'invalid token');
$test_client->status->set('disabled', 1, 'test status');
$params->{token} = $token;
$c->call_ok($method, $params)->has_error->error_code_is('DisabledClient')->error_message_is('This account is unavailable.', 'invalid token');

$test_client->status->clear_disabled;
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')
    ->error_message_is('Sorry, this feature is available to virtual accounts only', 'topup virtual error');

$params->{token} = $token_vr;
$c->call_ok($method, $params)->has_no_error->result_is_deeply(expected_result($amount), 'topup account successfully');
my $balance = $account->balance + 0;
is($old_balance + $amount, $balance, 'balance is right');
$old_balance = $balance;
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')
    ->error_message_is('You can only request additional funds if your virtual account balance falls below USD 1000.00.', 'balance is higher');
#withdraw some money to test critical limit value
my $limit            = 1000;
my $withdrawal_money = $balance - $limit - 1;
$test_client_vr->payment_legacy_payment(
    currency     => 'USD',
    amount       => -$withdrawal_money,
    payment_type => 'virtual_credit',
    remark       => 'virtual money withdrawal'
);
$balance = $account->balance + 0;
is($balance, $limit + 1, 'balance is a little less than the value of limit');
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')
    ->error_message_is('You can only request additional funds if your virtual account balance falls below USD 1000.00.', 'balance is higher');

$test_client_vr->payment_legacy_payment(
    currency     => 'USD',
    amount       => -1,
    payment_type => 'virtual_credit',
    remark       => 'virtual money withdrawal'
);
$balance = $account->balance + 0;
is($balance, $limit, 'balance is equal to limit');
$c->call_ok($method, $params)->has_no_error->result_is_deeply(expected_result($amount), 'topup account successfully');
$balance = $account->balance + 0;
is($balance, $limit + $amount, 'balance is topuped');

# buy a contract to test the error of 'Please close out all open positions before requesting additional funds.'
$test_client_vr->payment_legacy_payment(
    currency     => 'USD',
    amount       => -$amount,
    payment_type => 'virtual_credit',
    remark       => 'virtual money withdrawal'
);
$balance = $account->balance + 0;
is($balance, $limit, 'balance is equal to limit');
my $price         = 100;
my $contract_data = {
    underlying   => $underlying,
    bet_type     => 'PUT',
    currency     => 'USD',
    stake        => $price,
    date_start   => $now->epoch,
    date_expiry  => $now->epoch + 50,
    current_tick => $tick,
    entry_tick   => $old_tick1,
    exit_tick    => $tick2,
    barrier      => 'S0P',
};
my $txn_data = {
    client              => $test_client_vr,
    contract_parameters => $contract_data,
    price               => $price,
    amount_type         => 'stake',
    purchase_date       => $now->epoch,
};
my $txn = BOM::Transaction->new($txn_data);
is($txn->buy(skip_validation => 1), undef, 'buy contract without error');
$balance = $account->balance + 0;
is($balance, $limit - $price, 'balance is reduced for buying contract');
$c->call_ok($method, $params)->has_no_error->result_is_deeply(expected_result($amount), 'topup account successfully');
$balance = $account->balance + 0;
is($balance, $limit + $amount - $price, 'balance was increased correctly');

done_testing();
