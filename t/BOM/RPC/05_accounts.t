use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

package MojoX::JSON::RPC::Client;

sub tcall {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    return $self->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $params
        })->result;
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

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->add_loginid({loginid => $test_client_vr->loginid});
$user->save;
################################################################################
# test
################################################################################

my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

my $method = 'payout_currencies';
subtest $method => sub {
    my $m               = ref(BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica'));
    my $mocked_m        = Test::MockModule->new($m, no_auto => 1);
    my $mocked_currency = [qw(A B C)];
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), ['USD'], "will return client's currency");
    $mocked_m->mock('legal_allowed_currencies', sub { return $mocked_currency });
    is_deeply($c->tcall($method, {}), $mocked_currency, "will return legal currencies");
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
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    $mock_client->mock('default_account', sub { undef });
    is($c->tcall($method, {client_loginid => 'CR0021'})->{count}, 0, 'have 0 statements if no default account');
    undef $mock_client;
    my $mock_Portfolio          = Test::MockModule->new('BOM::RPC::v3::PortfolioManagement');
    my $_sell_expired_is_called = 0;
    $mock_Portfolio->mock('_sell_expired_contracts',
        sub { $_sell_expired_is_called = 1; $mock_Portfolio->original('_sell_expired_contracts')->(@_) });
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
            'short_code'              => 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5',
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
            'short_code'              => 'RUNBET_DOUBLEDOWN_USD2500_frxUSDJPY_5',
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
    my $result = $c->tcall($method, {client_loginid => 'CR0021'});
    ok($_sell_expired_is_called, "_sell_expired_contracts is called");
    is($result->{transactions}[0]{transaction_time}, Date::Utility->new($txns->[0]{purchase_time})->epoch, 'transaction time correct for buy ');
    is($result->{transactions}[1]{transaction_time}, Date::Utility->new($txns->[1]{sell_time})->epoch,     'transaction time correct for sell');
    is($result->{transactions}[2]{transaction_time}, Date::Utility->new($txns->[2]{payment_time})->epoch,  'transaction time correct for payment');

    # this function simple_contract_info is 'loaded' into module Accounts, So mock this module
    my $mocked_account = Test::MockModule->new('BOM::RPC::v3::Accounts');
    $mocked_account->mock('simple_contract_info', sub { return ("mocked info") });
    $result = $c->tcall(
        $method,
        {
            client_loginid => 'CR0021',
            args           => {description => 1}});
    is($result->{transactions}[0]{longcode}, "mocked info", "if have short code, then simple_contract_info is called");
    is($result->{transactions}[2]{longcode}, $txns->[2]{payment_remark}, "if no short code, then longcode is the remark");

};

$method = 'balance';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need a valid client');
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    $mock_client->mock('default_account', sub { undef });
    is($c->tcall($method, {client_loginid => 'CR0021'})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {client_loginid => 'CR0021'})->{currency}, '', 'have no currency if no default account');
    undef $mock_client;
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
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    my %status      = (
        status1      => 1,
        tnc_approval => 1,
        status2      => 0
    );
    $mock_client->mock('client_status_types', sub { return \%status });
    $mock_client->mock('get_status', sub { my ($self, $status) = @_; return $status{$status} });
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), {status => [qw(status1)]}, 'no tnc_approval, no status with value 0');
    %status = (tnc_approval => 1);
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), {status => [qw(active)]}, 'status no tnc_approval, but if no result, it will active');
    %status = ();
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), {status => [qw(active)]}, 'no result, active');
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
    my $send_email_called = 0;
    my $mocked_account    = Test::MockModule->new('BOM::RPC::v3::Accounts');
    $mocked_account->mock('send_email', sub { $send_email_called++ });
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    $user->load;
    isnt($user->password, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->password, $hash_pwd, 'client password updated');
    ok($send_email_called, 'send_email called');
    $password = $new_password;
};

$method = 'cashier_password';
subtest $method => sub {

    #test lock
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code},             'AuthorizationRequired', 'need a valid client');
    is($c->tcall($method, {client_loginid => $test_client_vr->loginid})->{error}{code}, 'PermissionDenied',      'need real money account');
    my $params = {
        client_loginid => $test_loginid,
        args           => {}};
    is($c->tcall($method, $params)->{status}, 0, 'no unlock_password && lock_password, and not set password before, status will be 0');
    my $tmp_password     = 'sfjksfSFjsk78Sjlk';
    my $tmp_new_password = 'bjxljkwFWf278xK';
    $test_client->cashier_setting_password($tmp_password);
    $test_client->save;
    is($c->tcall($method, $params)->{status}, 1, 'no unlock_password && lock_password, and set password before, status will be 1');
    $params->{args}{lock_password} = $tmp_new_password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was locked.', 'return error if already locked');
    $test_client->cashier_setting_password('');
    $test_client->save;
    $params->{args}{lock_password} = $password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Please use a different password than your login password.',
        'return error if lock password same with user password'
    );
    $params->{args}{lock_password} = '1111111';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Password is not strong enough.', 'check strong');
    $params->{args}{lock_password} = $tmp_new_password;
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save password'
    );
    $mocked_client->unmock_all;
    my $send_email_called = 0;
    my $mocked_account    = Test::MockModule->new('BOM::RPC::v3::Accounts');
    $mocked_account->mock('send_email', sub { $send_email_called++ });
    is($c->tcall($method, $params)->{status}, 1, 'set password success');
    ok($send_email_called, "email sent");

    # test unlock
    $test_client->cashier_setting_password('');
    $test_client->save;
    delete $params->{args}{lock_password};
    $params->{args}{unlock_password} = '123456';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was not locked.', 'return error if not locked');
    $test_client->cashier_setting_password(BOM::System::Password::hashpw($tmp_password));
    $test_client->save;
    $send_email_called = 0;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, you have entered an incorrect cashier password',
        'return error if not correct'
    );
    ok($send_email_called, 'send email if entered wrong password');
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{unlock_password} = $tmp_password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;
    $send_email_called = 0;
    is($c->tcall($method, $params)->{status}, 0, 'unlock password ok');
    $test_client->load;
    ok(!$test_client->cashier_setting_password, 'cashier password unset');
    ok($send_email_called,                      'send email after unlock cashier');
};

$method = 'get_settings';
subtest $method => sub{
  #diag(Dumper($c->tcall($method, {})));
  is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code}, 'AuthorizationRequired', 'need loginid');
  my $params = {client_loginid => 'CR0021', language => 'EN'};
  my $result = $c->tcall($method, $params);
  is_deeply($result,{
                     'country' => 'Australia',
                     'salutation' => 'Ms',
                     'is_authenticated_payment_agent' => '0',
                     'country_code' => 'au',
                     'date_of_birth' => '315532800',
                     'address_state' => '',
                     'address_postcode' => '85010',
                     'phone' => '069782001',
                     'last_name' => 'tee',
                     'email' => 'shuwnyuan@regentmarkets.com',
                     'address_line_2' => 'Jln Address 2 Jln Address 3 Jln Address 4',
                     'address_city' => 'Segamat',
                     'address_line_1' => '53, Jln Address 1',
                     'first_name' => 'shuwnyuan'
                    });

  ok(1);
};
done_testing();
