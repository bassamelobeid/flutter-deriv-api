use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);


package MojoX::JSON::RPC::Client;
use Data::Dumper;
use Test::Most;
sub tcall {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r = $self->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $params
        });
    ok($r->result, 'rpc response ok');
    ok(!$r->is_error, 'rpc response ok');
    if($r->is_error){
      diag(Dumper($r));
    }
    return $r->result;
}


package main;

################################################################################
# init db
################################################################################
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client->email($email);
$test_client->save;
my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->save;
clear_mailbox();

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
                                                      'currency',
                                                      {
                                                       symbol => $_,
                                                       date   => Date::Utility->new,
                                                      }) for qw(JPY USD JPY-USD);

my $now       = Date::Utility->new('2005-09-21 06:46:00');
my $underlying      = BOM::Market::Underlying->new('R_50');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
                                                      'randomindex',
                                                      {
                                                       symbol => 'R_50',
                                                       date   => $now,
                                                      });

################################################################################
# test
################################################################################

my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

my $method = 'payout_currencies';
subtest $method => sub {
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), ['USD'], "will return client's currency");
    is_deeply($c->tcall($method, {}), [qw(USD EUR GBP AUD)] , "will return legal currencies");
};

$method = 'landing_company';
subtest $method => sub {
    is_deeply(
        $c->tcall($method, {args => {landing_company => 'nosuchcountry'}}),
        {
            error => {
                message_to_client => 'Unknown landing company.',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
    ok($ag_lc->{gaming_company},    "ag have gaming company");
    ok($ag_lc->{financial_company}, "ag have financial company");
    ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company},    "de have no gaming_company");
    ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest $method => sub {
    is_deeply(
        $c->tcall($method, {args => {landing_company_details => 'nosuchcountry'}}),
        {
            error => {
                message_to_client => 'Unknown landing company.',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    is($c->tcall($method, {args => {landing_company_details => 'costarica'}})->{name}, 'Binary (C.R.) S.A.', "details result ok");
};

$method = 'statement';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need a valid client');
    is($c->tcall($method, {client_loginid => 'CR0021'})->{count}, 100, 'have 100 statements');
    is($c->tcall($method, {client_loginid => $test_loginid})->{count}, 0, 'have 0 statements if no default account');
    my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
    $test_client2->payment_free_gift(
            currency => 'USD',
            amount   => 1000,
            remark   => 'free gift',
        );



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
                                                                       });

            my $contract_expired = produce_contract({
                                                     underlying   => $underlying,
                                                     bet_type     => 'FLASHU',
                                                     currency     => 'USD',
                                                     stake        => 100,
                                                     date_start   => $now->epoch - 100,
                                                     date_expiry  => $now->epoch - 50,
                                                     current_tick => $tick,
                                                     entry_tick   => $old_tick1,
                                                     exit_tick    => $old_tick2,
                                                     barrier      => 'S0P',
                                                    });

    my $txn = BOM::Product::Transaction->new({
                                              client        => $test_client2,
                                              contract      => $contract_expired,
                                              price         => 100,
                                              payout        => $contract_expired->payout,
                                              amount_type   => 'stake',
                                              purchase_date => $now->epoch - 101,
                                             });

    $txn->buy(skip_validation => 1);
    my $result = $c->tcall($method, {client_loginid => $test_client2->loginid});
    is($result->{transactions}[0]{action_type},'sell', 'the transaction is sold, so _sell_expired_contracts is called');
    $result = $c->tcall(
                        $method,
                        {
                         client_loginid => $test_client2->loginid,
                         args           => {description => 1}});

    is($result->{transactions}[0]{longcode}, "USD 20.00 payout if USD/JPY is strictly higher than entry spot plus  10 pips at 30 minutes after contract start time.", "if have short code, then simple_contract_info is called");
    is($result->{transactions}[2]{longcode}, $txns->[2]{payment_remark}, "if no short code, then longcode is the remark");

    ################################################################################
    # Here I want to test the time of result
    #I cannot control the value of timestamp fields
    #So I mocked the result of transactions
    my $mocked_transaction = Test::MockModule->new('BOM::Database::DataMapper::Transaction');
    my $txns               = [{
            'staff_loginid'           => 'CR0021',
            'source'                  => undef,
            'sell_time'               => undef,
            'transaction_time'        => '2005-09-21 06:46:00',
            'action_type'             => 'buy',
            'referrer_type'           => 'financial_market_bet',
            'financial_market_bet_id' => '202339',
            'payment_id'              => undef,
            'id'                      => '204459',
            'purchase_time'           => '2005-09-21 06:46:00',
            'short_code'              => 'CALL_FRXUSDJPY_20_1311574735_1311576535_S10P_0',
            'balance_after'           => '505.0000',
            'remark'                  => undef,
            'quantity'                => 1,
            'payment_time'            => undef,
            'account_id'              => '200359',
            'amount'                  => '-10.0000',
            'payment_remark'          => undef
        },
        {
            'staff_loginid'           => 'CR0021',
            'source'                  => undef,
            'sell_time'               => undef,
            'transaction_time'        => '2005-09-21 06:46:00',
            'action_type'             => 'sell',
            'referrer_type'           => 'financial_market_bet',
            'financial_market_bet_id' => '202319',
            'payment_id'              => undef,
            'id'                      => '204439',
            'purchase_time'           => '2005-09-21 06:46:00',
            'short_code'              => 'CALL_FRXUSDJPY_20_1311574735_1311576535_S10P_0',
            'balance_after'           => '515.0000',
            'remark'                  => undef,
            'quantity'                => 1,
            'payment_time'            => undef,
            'account_id'              => '200359',
            'amount'                  => '237.5000',
            'payment_remark'          => undef
        },
        {
            'staff_loginid'           => 'CR0021',
            'source'                  => undef,
            'sell_time'               => undef,
            'transaction_time'        => '2005-09-21 06:14:00',
            'action_type'             => 'deposit',
            'referrer_type'           => 'payment',
            'financial_market_bet_id' => undef,
            'payment_id'              => '200599',
            'id'                      => '201399',
            'purchase_time'           => undef,
            'short_code'              => undef,
            'balance_after'           => '600.0000',
            'remark'                  => undef,
            'quantity'                => 1,
            'payment_time'            => '2005-09-21 06:14:00',
            'account_id'              => '200359',
            'amount'                  => '600.0000',
            'payment_remark' =>
                'Egold deposit Batch 49100734 from egold ac 2427854 (1.291156 ounces of Gold at $464.70/ounce) Egold Timestamp 1127283282'
        }];

    $mocked_transaction->mock('get_transactions_ws', sub { return $txns });
    $result = $c->tcall($method, {client_loginid => 'CR0021'});
    #ok($_sell_expired_is_called, "_sell_expired_contracts is called");
    is($result->{transactions}[0]{transaction_time}, Date::Utility->new($txns->[0]{purchase_time})->epoch, 'transaction time correct for buy ');
    is($result->{transactions}[1]{transaction_time}, Date::Utility->new($txns->[1]{sell_time})->epoch,     'transaction time correct for sell');
    is($result->{transactions}[2]{transaction_time}, Date::Utility->new($txns->[2]{payment_time})->epoch,  'transaction time correct for payment');

};

$method = 'balance';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need a valid client');
    is($c->tcall($method, {client_loginid => $test_loginid})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {client_loginid => $test_loginid})->{currency}, '', 'have no currency if no default account');
    my $result = $c->tcall($method, {client_loginid => 'CR0021'});
    is_deeply(
        $result,
        {
            'currency' => 'USD',
            'balance'  => '1505.0000',
            'loginid'  => 'CR0021'
        },
        'result is correct'
    );
};

$method = 'get_account_status';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need a valid client');
    is_deeply($c->tcall($method, {client_loginid => $test_loginid}), {status => [qw(active)]}, 'no result, active');
    $test_client->set_status('tnc_approval','test staff', 1);
    $test_client->save();
    is_deeply($c->tcall($method, {client_loginid => $test_loginid}), {status => [qw(active)]}, 'status no tnc_approval, but if no result, it will active');
    $test_client->set_status('ok','test staff',1);
    $test_client->save();
    is_deeply($c->tcall($method, {client_loginid => $test_loginid}), {status => [qw(ok)]}, 'no tnc_approval');

};

$method = 'change_password';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need a valid client');
    my $params = {client_loginid => $test_loginid};
    is($c->tcall($method, $params)->{error}{code}, 'PermissionDenied', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{code}, 'PermissionDenied', 'need token_type');
    $params->{token_type}         = 'session_token';
    $params->{args}{old_password} = 'old_password';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Old password is wrong.');
    $params->{args}{old_password} = $password;
    $params->{args}{new_password} = $password;

    is($c->tcall($method, $params)->{error}{message_to_client}, 'New password is same as old password.');
    $params->{args}{new_password} = '111111111';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Password is not strong enough.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;

    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my %msg = get_email_by_address_subject(email => $email,subject => qr/Your password has been changed/);
    ok(%msg, "email received");
    clear_mailbox();
    $user->load;
    isnt($user->password, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->password, $hash_pwd, 'client password updated');
    $password = $new_password;
};

done_testing();
