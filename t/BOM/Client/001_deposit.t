#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Deposit;

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::Deep;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::Password;
use BOM::Rules::Engine;

use Date::Utility;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client_details = {
    broker_code              => 'CR',
    residence                => 'au',
    client_password          => 'x',
    last_name                => 'shuwnyuan',
    first_name               => 'tee',
    email                    => 'shuwnyuan@regentmarkets.com',
    salutation               => 'Ms',
    address_line_1           => 'ADDR 1',
    address_city             => 'Segamat',
    phone                    => '+60123456789',
    secret_question          => "Mother's maiden name",
    secret_answer            => 'blah',
    non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
};

my $client = $user->create_client(%$client_details);
$client->set_default_account('USD');
my %deposit = (
    currency     => 'USD',
    amount       => 1_000,
    remark       => 'here is money',
    payment_type => 'free_gift',
    rule_engine  => BOM::Rules::Engine->new(client => $client),
);

$client->status->set('unwelcome', 'calum', '..dont like you, sorry.');

is_deeply exception { $client->validate_payment(%deposit) },
    {
    code              => 'UnwelcomeStatus',
    params            => ['CR10000'],
    message_to_client => 'Your account is restricted to withdrawals only.'
    },
    'cannot deposit when unwelcome';

$client->status->clear_unwelcome;

ok $client->validate_payment(%deposit), 'can deposit when not unwelcome.';

$client->status->set('disabled', 'calum', '..dont like you, sorry.');

is_deeply exception { $client->validate_payment(%deposit) },
    {
    code              => 'DisabledAccount',
    params            => ['CR10000'],
    message_to_client => 'Your account is disabled.'
    },
    'cannot deposit when disabled';

$client->status->clear_disabled;

ok $client->validate_payment(%deposit), 'can deposit when not disabled.';

$client->status->set('cashier_locked', 'calum', '..dont like you, sorry.');

is_deeply exception { $client->validate_payment(%deposit) },
    {
    code              => 'CashierLocked',
    params            => [],
    message_to_client => 'Your cashier is locked.'
    },
    'cannot deposit when cashier is locked';

$client->status->clear_cashier_locked;

ok $client->validate_payment(%deposit), 'can deposit when not cashier locked.';

ok(!$client->status->unwelcome, 'CR client not unwelcome prior to first-deposit');
$client->payment_free_gift(%deposit);
ok(!$client->status->unwelcome, 'CR client still not unwelcome after first-deposit');

subtest 'max balance messages' => sub {

    if ($client->landing_company->unlimited_balance) {
        ok $client->validate_payment(%deposit, amount => 1_000_000), 'can deposit unlimited balance.';
    } else {
        is_deeply exception { $client->validate_payment(%deposit, amount => 1_000_000) },
            {
            code              => 'BalanceExceeded',
            params            => [300_000, 'USD'],
            message_to_client => 'This deposit will cause your account balance to exceed your account limit of 300000 USD.'
            },
            'cannot deposit an amount that puts client over maximum balance';
    }

    $client->set_exclusion();
    $client->self_exclusion->max_balance(1000);
    $client->save;

    if ($client->landing_company->unlimited_balance) {
        ok $client->validate_payment(%deposit, amount => 1_000_000), 'can deposit unlimited balance.';
    } else {
        is_deeply exception { $client->validate_payment(%deposit, amount => 1_000_000) },
            {
            code              => 'SelfExclusionLimitExceeded',
            params            => [1000, 'USD'],
            message_to_client =>
                "This deposit will cause your account balance to exceed your limit of 1000 USD. To proceed with this deposit, please adjust your self exclusion settings.",
            },
            'cannot deposit an amount that puts client over self exclusion max balance.';
    }
};

subtest 'GB fund protection' => sub {
    my $email_mf  = 'test' . rand(999) . '@binary.com';
    my $passwd_mf = BOM::User::Password::hashpw('Qwerty12345');

    my $user_mf = BOM::User->create(
        email    => $email_mf,
        password => $passwd_mf
    );

    my $client_details_mf = {
        broker_code              => 'MF',
        residence                => 'gb',
        client_password          => $passwd_mf,
        last_name                => 'Test',
        first_name               => 'Test',
        email                    => $email_mf,
        salutation               => 'Ms',
        address_line_1           => 'ADDR 1',
        address_city             => 'Test',
        phone                    => '+60123456789',
        secret_question          => "Mother's maiden name",
        secret_answer            => 'Test',
        non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
    };

    my %deposit_mf = (
        currency     => 'GBP',
        amount       => 1_000,
        remark       => 'credit',
        payment_type => 'free_gift'
    );
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(fully_authenticated => 1);
    my $client_mf = $user_mf->create_client(%$client_details_mf);
    $client_mf->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $client_mf->status->set('crs_tin_information',     'test',   'test');
    $client_mf->set_default_account('GBP');
    $deposit_mf{rule_engine} = BOM::Rules::Engine->new(client => $client_mf);
    $client_mf->status->set('ukgc_funds_protection', 'system', 'testing');
    ok $client_mf->validate_payment(%deposit_mf), 'can deposit when no deposit limit set.';
    $mock_client->unmock_all;
};

subtest 'deposit limit' => sub {
    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(
        deposit_limit_enabled => sub {
            my $lc = shift;
            return $lc->short eq 'mf';
        });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(fully_authenticated => 1);

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_mf->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $client_mf->status->set('crs_tin_information',     'test',   'test');
    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr, $client_mf]);
    for my $client ($client_mf, $client_cr) {
        $client->set_default_account('USD');
        is_deeply $client->get_deposit_limits, {}, 'deposit settings are empty in the beginning';
        $client->set_exclusion();
        $user->add_client($client);
    }

    my %limit_duration_to_name = (
        '30' => 'max_deposit_30day',
        '7'  => 'max_deposit_7day',
        '1'  => 'max_deposit_daily'
    );

    for my $limit_duration (30, 7, 1) {
        my $limit_name   = $limit_duration_to_name{$limit_duration};
        my $limit_amount = $limit_duration * 100;

        for my $client ($client_mf, $client_cr) {
            $client->self_exclusion->$limit_name($limit_amount);
            $client->save;

            is_deeply $client->get_deposit_limits, {$limit_name =~ s/max_deposit_//r => $limit_amount}, 'Deposit limits are updated';

            $client->payment_free_gift(
                currency => 'USD',
                amount   => $limit_amount,
                remark   => 'initial deposit',
            );
        }

        my $payment      = $client->db->dbic->run(fixup => sub { $_->selectrow_hashref("SELECT * FROM payment.payment ORDER BY id DESC LIMIT 1"); });
        my $payment_time = Date::Utility->new($payment->{payment_time})->epoch;

        my $one_usd_payment = {
            currency    => 'USD',
            amount      => 1,
            remark      => 'additional deposit',
            rule_engine => $rule_engine,
        };

        # move time forward to 1 day less than limit duration
        set_fixed_time($payment_time + ($limit_duration - 1) * 86400);

        my $short_name = $limit_name =~ s/max_deposit_//r;

        lives_ok { $client_cr->validate_payment(%$one_usd_payment) } "we can deposit if deposit limits are disabled for the landing company";

        # move time forward exactly the same number of days as limit duration
        set_fixed_time($payment_time + ($limit_duration + 1) * 86400);
        lives_ok { $client_mf->validate_payment(%$one_usd_payment) } "we can deposit if the $limit_duration-day limit duration is passed";
        lives_ok { $client_cr->validate_payment(%$one_usd_payment) } "we can deposit to the limit-diasbled landing company any time, can' t we? ";

        $_->self_exclusion->$limit_name(undef)                            for ($client_mf, $client_cr);
        is_deeply($_->get_deposit_limits, {}, 'deposit limits are reset') for ($client_mf, $client_cr);
        restore_time();
    }

    $mock_lc->unmock_all();
};

done_testing();
