#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Deposit;

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::Password;

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

my %deposit = (
    currency     => 'USD',
    amount       => 1_000,
    remark       => 'here is money',
    payment_type => 'free_gift'
);

my $client = $user->create_client(%$client_details);
$client->set_default_account('USD');

$client->status->set('unwelcome', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Your account is restricted to withdrawals only./, 'cannot deposit when unwelcome.';

$client->status->clear_unwelcome;

ok $client->validate_payment(%deposit), 'can deposit when not unwelcome.';

$client->status->set('disabled', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Your account is disabled/, 'cannot deposit when disabled.';

$client->status->clear_disabled;

ok $client->validate_payment(%deposit), 'can deposit when not disabled.';

$client->status->set('cashier_locked', 'calum', '..dont like you, sorry.');

throws_ok { $client->validate_payment(%deposit) } qr/Your cashier is locked/, 'cannot deposit when cashier is locked.';

$client->status->clear_cashier_locked;

ok $client->validate_payment(%deposit), 'can deposit when not cashier locked.';

throws_ok { $client->validate_payment(%deposit, amount => 1_000_000) } qr/Balance would exceed/,
    'cannot deposit an amount that puts client over maximum balance.';

ok(!$client->status->unwelcome, 'CR client not unwelcome prior to first-deposit');
$client->payment_free_gift(%deposit);
ok(!$client->status->unwelcome, 'CR client still not unwelcome after first-deposit');

subtest 'GB fund protection' => sub {
    my $email_iom  = 'test' . rand(999) . '@binary.com';
    my $passwd_iom = BOM::User::Password::hashpw('Qwerty12345');

    my $user_iom = BOM::User->create(
        email    => $email_iom,
        password => $passwd_iom
    );

    my $client_details_iom = {
        broker_code              => 'MX',
        residence                => 'gb',
        client_password          => $passwd_iom,
        last_name                => 'Test',
        first_name               => 'Test',
        email                    => $email_iom,
        salutation               => 'Ms',
        address_line_1           => 'ADDR 1',
        address_city             => 'Test',
        phone                    => '+60123456789',
        secret_question          => "Mother's maiden name",
        secret_answer            => 'Test',
        non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
    };

    my %deposit_iom = (
        currency     => 'GBP',
        amount       => 1_000,
        remark       => 'credit',
        payment_type => 'free_gift'
    );

    my $client_iom = $user_iom->create_client(%$client_details_iom);
    $client_iom->set_default_account('GBP');

    throws_ok { $client_iom->validate_payment(%deposit_iom) } qr/Please accept Funds Protection./, 'GB residence needs to accept fund protection';

    $client_iom->status->set('ukgc_funds_protection', 'system', 'testing');
    ok $client_iom->validate_payment(%deposit_iom), 'can deposit when no deposit limit set.';
};

subtest 'deposit limit' => sub {
    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(
        deposit_limit_enabled => sub {
            my $lc = shift;
            return $lc->short eq 'iom';
        });

    my $client_iom = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MX'});
    my $client_cr  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    for my $client ($client_iom, $client_cr) {
        $client->set_default_account('USD');
        is_deeply $client->get_deposit_limits, {}, 'depost settings are empty in the beginning';
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

        for my $client ($client_iom, $client_cr) {
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
            currency => 'USD',
            amount   => 1,
            remark   => 'additional deposit',
        };

        # move time forward to 1 day less than limit duration
        set_fixed_time($payment_time + ($limit_duration - 1) * 86400);

        my $short_name = $limit_name =~ s/max_deposit_//r;
        throws_ok { $client_iom->validate_payment(%$one_usd_payment) } qr/Deposit exceeds $short_name limit/,
            "cannot deposit when amount exceeds $limit_duration-day deposit limit.";
        lives_ok { $client_cr->validate_payment(%$one_usd_payment) } "we can deposit if deposit limits are disabled for the landing company";

        # move time forward exactly the same number of days as limit duration
        set_fixed_time($payment_time + ($limit_duration + 1) * 86400);
        lives_ok { $client_iom->validate_payment(%$one_usd_payment) } "we can deposit if the $limit_duration-day limit duration is passed";
        lives_ok { $client_cr->validate_payment(%$one_usd_payment) } "we can deposit to the limit-diasbled landing company any time, can' t we? ";

        $_->self_exclusion->$limit_name(undef)                            for ($client_iom, $client_cr);
        is_deeply($_->get_deposit_limits, {}, 'deposit limits are reset') for ($client_iom, $client_cr);
        restore_time();
    }

    $mock_lc->unmock_all();
};

done_testing();
