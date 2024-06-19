use strict;
use warnings;

use Test::More qw(no_plan);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::User::Password;
use BOM::User::Wallet;
use Test::MockModule;
use Test::Fatal;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@deriv.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $details = {
    broker_code              => 'CRW',
    currency                 => 'USD',
    salutation               => 'Ms',
    last_name                => 'last-name',
    first_name               => 'first-name',
    myaffiliates_token       => '',
    date_of_birth            => '1979-01-01',
    citizen                  => 'au',
    residence                => 'au',
    email                    => 'test-wallet@regentmarkets.com',
    address_line_1           => 'ADDR 1',
    address_line_2           => 'ADDR 2',
    address_city             => 'Cyberjaya',
    address_state            => 'State',
    address_postcode         => '55010',
    phone                    => '+60123456789',
    client_password          => '123456',
    secret_question          => '',
    secret_answer            => '',
    binary_user_id           => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
    non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
    fatca_declaration_time   => Date::Utility->new('20010108')->date_yyyymmdd,
    fatca_declaration        => 1,
    account_type             => 'doughflow',
    landing_company          => "svg"

};

subtest 'Lock check' => sub {
    # Simulate situation when lock already aquired
    my $mock = Test::MockModule->new('BOM::Platform::Redis');
    $mock->mock(acquire_lock => 0);

    my $err = exception { $user->create_wallet(%$details) };

    ok $err, 'Got an error';
    like $err, qr{User \d+ is trying to create 2 wallets at the same time}, 'Got valid error message';
};

subtest 'create a real wallet CRW' => sub {

    my $wallet = $user->create_wallet(%$details);

    is $wallet->is_wallet, 1, 'is wallet client instance';

    is($wallet->account_type, 'doughflow', 'Account type is correct');

    is($wallet->currency, 'USD', 'Wallet Currecny Code: USD');

    is($wallet->landing_company->short, 'svg', 'Wallet LC Code: svg');
};

subtest 'Dublicate check' => sub {
    my $err = exception { $user->create_wallet(%$details) };

    ok $err, 'Got error in case of creating dublicate wallet account';
    is ref $err,      'HASH',            'Error is a hash';
    is $err->{error}, 'DuplicateWallet', 'Error contains valid error code';
};

subtest 'create a real wallet MFW' => sub {

    $details->{landing_company} = 'maltainvest';
    $details->{broker_code}     = 'MFW';
    my $wallet = $user->create_wallet(%$details);

    is $wallet->is_wallet, 1, 'is wallet client instance';

    is($wallet->account_type, 'doughflow', 'Account type is correct');

    is($wallet->currency, 'USD', 'Wallet Currecny Code: USD');

    is($wallet->landing_company->short, 'maltainvest', 'Wallet LC Code: maltainvest');
};

done_testing();
