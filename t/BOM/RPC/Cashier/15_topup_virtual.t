use strict;
use warnings;

use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw( produce_contract );
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

my $token = BOM::Platform::SessionCookie->new(
                                              loginid => $test_loginid,
                                              email   => $email
                                             )->token;
my $token_vr = BOM::Platform::SessionCookie->new(
                                                 loginid => $test_client_vr->loginid,
                                                 email   => $email
                                                )->token;
my $account = $test_client_vr->default_account;
my $old_balance = $account->balance;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

my $now        = Date::Utility->new('2005-09-21 06:46:00');
my $underlying = BOM::Market::Underlying->new('R_50');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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

my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 52,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
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


my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $amount = BOM::Platform::Runtime->instance->app_config->payments->virtual->topup_amount->USD;

# start test topup_virtual
my $method = 'topup_virtual';
my $params = {
              language => 'zh_CN',
              token    => '12345'
             };


$c->call_ok($method, $params)->has_error->error_code_is('InvalidToken')->error_message_is('令牌无效。', 'invalid token');

$test_client->set_status('disabled',1, 'test status');
$test_client->save;
$params->{token} = $token;
$c->call_ok($method, $params)->has_error->error_code_is('DisabledClient')->error_message_is('此账户不可用。', 'invalid token');

$test_client->clr_status('disabled');
$test_client->save;
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')->error_message_is('对不起，此功能仅适用虚拟账户', 'topup virtual error');

$params->{token} = $token_vr;
$c->call_ok($method, $params)->has_no_error->result_is_deeply({currency => 'USD', amount => $amount}, 'topup account successfully');
$account->load;
my $balance = $account->balance + 0;
is($old_balance + $amount, $balance, 'balance is right');
$old_balance = $balance;
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')->error_message_is('您的余款已超出允许金额。', 'blance is higher');
#withdraw some money to test critical limit value
my $limit = BOM::Platform::Runtime->instance->app_config->payments->virtual->minimum_topup_balance->USD;
my $withdrawal_money = $balance - $limit - 1;
$test_client_vr->payment_legacy_payment(currency => 'USD', amount => - $withdrawal_money, payment_type => 'virtual_credit', remark => 'virtual money withdrawal');
$account->load;
$balance = $account->balance + 0;
is($balance, $limit + 1, 'balance is a little less than the value of limit');
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')->error_message_is('您的余款已超出允许金额。', 'blance is higher');

$test_client_vr->payment_legacy_payment(currency => 'USD', amount => -1 , payment_type => 'virtual_credit', remark => 'virtual money withdrawal');
$account->load;
$balance = $account->balance + 0;
is($balance, $limit, 'balance is equal to limit');
$c->call_ok($method, $params)->has_no_error->result_is_deeply({currency => 'USD', amount => $amount}, 'topup account successfully');
$account->load;
$balance = $account->balance + 0;
is($balance, $limit + $amount, 'balance is topuped');

# buy a contract to test the error of 'Please close out all open positions before requesting additional funds.'
$test_client_vr->payment_legacy_payment(currency => 'USD', amount => -$amount , payment_type => 'virtual_credit', remark => 'virtual money withdrawal');
$account->load;
$balance = $account->balance + 0;
is($balance, $limit, 'balance is equal to limit');
my $price = 100
my $contract_data = {
                     underlying   => $underlying,
                     bet_type     => 'FLASHD',
                     currency     => 'USD',
                     stake        => $price,
                     date_start   => $now->epoch,
                     date_expiry  => $now->epoch + 50,
                     current_tick => $tick,
                     entry_tick   => $old_tick1,
                     exit_tick    => $tick2,
                     barrier      => 'S0P',
                    };
    my $contract = produce_contract($contract_data);

my $txn_data = {
                client        => $test_client_vr,
                contract      => $contract,
                price         => $price,
                payout        => $contract->payout,
                amount_type   => 'stake',
                purchase_date => $now->epoch,
               };
    my $txn = BOM::Product::Transaction->new($txn_data);


is($txn->buy(skip_validation => 1),undef, 'buy contract without error');
$account->load;
$balance = $account->balance + 0;
is($balance, $limit - $price, 'balance is reduced for buying contract');
$c->call_ok($method, $params)->has_error->error_code_is('TopupVirtualError')->error_message_is('对不起，您还有未平仓的头寸。在请求额外资金前，请了结所有未平仓头寸。', 'have opened bets');
done_testing();
