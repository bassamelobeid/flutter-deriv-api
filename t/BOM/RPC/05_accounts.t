use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use MojoX::JSON::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;

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
my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->save;
################################################################################
# test
################################################################################

my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

#cleanup
BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid);

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
# need to mock it as to access api token we need token beforehand
$mock_utility->mock('token_to_loginid', sub { return $test_loginid });

# create new api token
my $res = BOM::RPC::v3::Accounts::api_token({
        token => 'Abc123',
        args  => {
            api_token => 1,
            new_token => 'Sample1'
        }});
is scalar(@{$res->{tokens}}), 1, "token created succesfully";
my $token = $res->{tokens}->[0]->{token};

$mock_utility->unmock('token_to_loginid');

my $method = 'payout_currencies';
subtest $method => sub {
    my $m               = ref(BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica'));
    my $mocked_m        = Test::MockModule->new($m, no_auto => 1);
    my $mocked_currency = [qw(A B C)];
    is_deeply($c->tcall($method, {token => $token}), ['EUR'], "will return client's currency");
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
    is($c->tcall($method, {})->{error}{code}, 'InvalidToken', 'need loginid');
    is($c->tcall($method, {token => 'some_dummy_token'})->{error}{code}, 'InvalidToken', 'need a valid client');
    is($c->tcall($method, {token => $token})->{count}, 100, 'have 100 statements');
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    $mock_client->mock('default_account', sub { undef });
    is($c->tcall($method, {token => $token})->{count}, 0, 'have 0 statements if no default account');
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
    my $result = $c->tcall($method, {token => $token});
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
            token => $token,
            args           => {description => 1}});
    is($result->{transactions}[0]{longcode}, "mocked info", "if have short code, then simple_contract_info is called");
    is($result->{transactions}[2]{longcode}, $txns->[2]{payment_remark}, "if no short code, then longcode is the remark");

};

$method = 'balance';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'InvalidToken', 'need loginid');
    is($c->tcall($method, {token => 'dummy'})->{error}{code}, 'InvalidToken', 'need a valid client');
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    $mock_client->mock('default_account', sub { undef });
    is($c->tcall($method, {token => $token})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {token => $token})->{currency}, '', 'have no currency if no default account');
    undef $mock_client;
    my $result = $c->tcall($method, {token => $token});
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
    is($c->tcall($method, {})->{error}{code}, 'InvalidToken', 'need loginid');
    is($c->tcall($method, {token => 'dummy'})->{error}{code}, 'InvalidToken', 'need a valid client');
    my $mock_client = Test::MockModule->new('BOM::Platform::Client');
    my %status      = (
        status1      => 1,
        tnc_approval => 1,
        status2      => 0
    );
    $mock_client->mock('client_status_types', sub { return \%status });
    $mock_client->mock('get_status', sub { my ($self, $status) = @_; return $status{$status} });
    is_deeply($c->tcall($method, {token => $token}), {status => [qw(status1)]}, 'no tnc_approval, no status with value 0');
    %status = (tnc_approval => 1);
    is_deeply($c->tcall($method, {token => $token}), {status => [qw(active)]}, 'status no tnc_approval, but if no result, it will active');
    %status = ();
    is_deeply($c->tcall($method, {token => $token}), {status => [qw(active)]}, 'no result, active');
};

$method = 'change_password';
subtest $method => sub {
    is($c->tcall($method, {})->{error}{code}, 'InvalidToken', 'need loginid');
    is($c->tcall($method, {token => 'dummy'})->{error}{code}, 'InvalidToken', 'need a valid client');
    my $params = {token => $token};
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

$res = BOM::RPC::v3::Accounts::api_token({
        token => $token,
        args  => {
            api_token    => 1,
            delete_token => $token
        }});
is scalar(@{$res->{tokens}}), 0, "token deleted successfully";

done_testing();
