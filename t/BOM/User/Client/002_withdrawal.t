#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Withdrawal;

use strict;
use warnings;

use Test::MockTime qw( set_fixed_time);
use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use File::Spec;
use JSON::MaybeXS;
use Date::Utility;
use Cache::RedisDB;

use ExchangeRates::CurrencyConverter qw/in_usd convert_currency/;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Future;

use BOM::User;
use BOM::User::Password;
use BOM::Rules::Engine;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

# Mocked currency converter to imitate currency conversions
my $mocked_payment_notification = Test::MockModule->new('BOM::User::Client::PaymentNotificationQueue');
$mocked_payment_notification->mock(
    add => sub {
        return Future->done;
    });

populate_exchange_rates({
    USD => 1,
    EUR => 1.1888,
    GBP => 1.3333,
    JPY => 0.0089,
    BTC => 5500,
    BCH => 320,
    LTC => 50,
});

my $recorded_date = Date::Utility->new;

my %new_client_details = (
    broker_code              => 'CR',
    residence                => 'br',
    client_password          => 'x',
    last_name                => 'binary',
    first_name               => 'test',
    email                    => 'binarytest@binary.com',
    salutation               => 'Ms',
    address_line_1           => 'ADDR 1',
    address_city             => 'Cyberjaya',
    phone                    => '+60123456789',
    place_of_birth           => 'br',
    secret_question          => "Mother's maiden name",
    secret_answer            => 'blah',
    non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
);

my %withdrawal = (
    currency     => 'USD',
    amount       => -100,
    payment_type => 'external_cashier',
    remark       => 'test withdrawal'
);
my %deposit = (
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my %deposit_eur    = (%deposit,    currency => 'EUR');
my %withdrawal_eur = (%withdrawal, currency => 'EUR');

my %deposit_btc    = (%deposit,    currency => 'BTC');
my %withdrawal_btc = (%withdrawal, currency => 'BTC');

my %deposit_ltc    = (%deposit,    currency => 'LTC');
my %withdrawal_ltc = (%withdrawal, currency => 'LTC');

sub new_client {
    my $currency = shift;
    my $c        = $user->create_client(%new_client_details, @_);
    $c->set_default_account($currency);

    my $rule_engine = BOM::Rules::Engine->new(client => $c);

    for my $payment (\%deposit, \%withdrawal, \%deposit_eur, \%withdrawal_eur, \%deposit_btc, \%withdrawal_btc, \%deposit_ltc, \%withdrawal_ltc) {
        $payment->{rule_engine} = $rule_engine;
    }

    return $c;
}

subtest 'General' => sub {
    plan tests => 1;
    my $client = new_client('USD');

    $client->smart_payment(%deposit);
    ok($client->validate_payment(%withdrawal), 'Withdrawals available under normal conditions.');
};

# Test for disables and locks
subtest 'Client-specific' => sub {
    plan tests => 4;
    my $client = new_client('USD');

    $client->status->set('withdrawal_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Your account is locked for withdrawals./, 'Client withdrawals have been locked.';
    $client->status->clear_withdrawal_locked;

    $client->status->clear_unwelcome;
    $client->status->set('disabled', 'a-payments-clerk', '..dont like you, sorry.');
    throws_ok { $client->validate_payment(%withdrawal) } qr/disabled/, 'Client disabled.';

    $client->status->set('cashier_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Your cashier is locked/, 'Client withdrawals have been locked.';
    $client->status->clear_cashier_locked;

    $client->status->setnx('disabled', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Your account is disabled/, 'Client withdrawals have been locked.';
    $client->status->clear_disabled;
};

# Test for withdrawals that the exceed client's balance
subtest "withdraw vs Balance" => sub {
    plan tests => 1;
    my $client = new_client('USD');
    $client->smart_payment(%deposit);
    throws_ok { $client->validate_payment(%withdrawal, amount => -100.01) } qr/Withdrawal amount \[.* USD\] exceeds client balance \[.* USD\]/,
        "Withdraw more than balance";
};

# Test for CR withdrawal limits
subtest 'CR withdrawal' => sub {
    plan tests => 6;

    # CR withdrawals in USD
    subtest 'in USD, unauthenticated' => sub {
        my $client = new_client('USD');
        my $dbh    = $client->dbh;

        my %emitted;
        my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
        $mock_events->mock(
            'emit',
            sub {
                my ($type, $data) = @_;
                $emitted{$data->{loginid}} = $type;
            });

        $client->smart_payment(%deposit, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal, amount => -10001) }
        qr/We're unable to process your withdrawal request because it exceeds the limit of 10000.00 USD. Please authenticate your account before proceeding with this withdrawal./,
            'Non-Authed CR withdrawal greater than USD10K';

        is_deeply exception { $client->validate_payment(%withdrawal, amount => -10001, die_with_error_object => 1) },
            {
            error_code => 'WithdrawalLimit',
            params     => ['10000.00', 'USD'],
            rule       => 'withdrawal.landing_company_limits'
            },
            'Correct message with die_with_error_object=1';

        lives_ok { $client->validate_payment(%withdrawal, amount => -10000) } 'Non-Authed CR withdrawal USD10K';

        lives_ok { $client->validate_payment(%withdrawal, amount => -9999) } 'Non-Authed CR withdrawal USD9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'first 5k withdrawal';
            throws_ok { $client->smart_payment(%withdrawal, amount => -5001) }
            qr/We're unable to process your withdrawal request because it exceeds the limit of 5000.00 USD. Please authenticate your account before proceeding with this withdrawal./,
                'total withdraw cannot > 10k';
            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'second 5k withdrawal';
            is($emitted{$client->loginid}, 'withdrawal_limit_reached', 'An event is emitted to set the client as needs_action');
            throws_ok { $client->validate_payment(%withdrawal, amount => -100) }
            qr/You've reached the maximum withdrawal limit of 10000.00 USD. Please authenticate your account before proceeding with this withdrawal/,
                'withdrawal_limit_reached';

            is_deeply exception { $client->validate_payment(%withdrawal, amount => -100, die_with_error_object => 1) },
                {
                error_code => 'WithdrawalLimitReached',
                params     => ['10000.00', 'USD'],
                rule       => 'withdrawal.landing_company_limits'
                },
                'Correct message with die_with_error_object=1';
        };

        $mock_events->unmock_all();
    };

    # CR withdrawals in EUR
    subtest 'in EUR, unauthenticated' => sub {
        my $client = new_client('EUR');
        my $var    = $client->smart_payment(%deposit_eur, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -10001) }
        qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ EUR. Please authenticate your account before proceeding with this withdrawal./,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8411.84) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8410.84) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_eur, amount => -5000) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_eur, amount => -5001) }
            qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ EUR. Please authenticate your account before proceeding with this withdrawal./,
                'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in BTC
    subtest 'in BTC, unauthenticated' => sub {
        my $client = new_client('BTC');
        my $var    = $client->smart_payment(%deposit_btc, amount => 3.00000000);
        throws_ok { $client->validate_payment(%withdrawal_btc, amount => -2) } qr/We're unable to process your withdrawal request/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.81818181) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.80000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_btc, amount => -0.90909090) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_btc, amount => -0.91000000) } qr/We're unable to process your withdrawal request/,
                'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in LTC
    subtest 'in LTC, unauthenticated' => sub {
        my $client = new_client('LTC');
        $client->smart_payment(%deposit_ltc, amount => 201.00000000);
        throws_ok { $client->validate_payment(%withdrawal_ltc, amount => -201.00000000) } qr/We're unable to process your withdrawal request/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -200.00000000) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -199.98000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_ltc, amount => -100.00000000) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_ltc, amount => -100.02000000) } qr/We're unable to process your withdrawal request/,
                'total withdraw cannot > 10k';
        };
    };

    # Fully authenticated CR withdrawals - No more limit
    subtest 'fully authenticated' => sub {
        my $client = new_client('USD');
        $client->status->set('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID',);
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->smart_payment(%deposit, amount => 20000);
        lives_ok { $client->validate_payment(%withdrawal, amount => -10000) } 'Authed CR withdrawal no more than USD10K';
        lives_ok { $client->validate_payment(%withdrawal, amount => -10001) } 'Authed CR withdrawal more than USD10K';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'first 5k withdrawal';
            lives_ok { $client->smart_payment(%withdrawal, amount => -6000) } 'subsequent 6k withdrawal';
        };
    };

    # Testing an odd case for validate_payment
    subtest 'BTC authenticated, full withdrawal' => sub {
        my $client = new_client('BTC');
        $client->status->setnx('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        my $var = $client->smart_payment(%deposit_btc, amount => 0.01434048);
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -0.01434048) } 'Authed CR withdraw full BTC amount';
        $client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    };
};

# Test for MX withdrawal limits
subtest 'EUR3k over 30 days MX limitation.' => sub {
    my $client = new_client(
        'GBP',
        broker_code => 'MX',
        residence   => 'gb',
        email       => 'binarygb@binary.com',
    );
    ok(!$client->fully_authenticated, 'client has not authenticated identity.');
    my $gbp_amount  = _GBP_equiv(6200);
    my %deposit_gbp = (
        %deposit,
        amount   => $gbp_amount,
        currency => 'GBP'
    );
    throws_ok { $client->validate_payment(%deposit_gbp) } qr/Please accept Funds Protection./, 'GB residence needs to accept fund protection';
    $client->status->set('ukgc_funds_protection', 'system', 'testing');
    $client->smart_payment(%deposit_gbp);
    $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

    ok $client->default_account->balance == $gbp_amount, 'Successfully credited client; no other amount has been credited to GBP account segment.';

    my %wd_gbp = (
        %withdrawal,
        currency => 'GBP',
        amount   => 0
    );

    # Set withdrawals to GBP equivalents of EUR 500, EUR 501, and so on
    my %wd0500 = (%wd_gbp, amount => -_GBP_equiv(500));
    my %wd0501 = (%wd_gbp, amount => -_GBP_equiv(501));
    my %wd2500 = (%wd_gbp, amount => -_GBP_equiv(2500));
    my %wd3000 = (%wd_gbp, amount => -_GBP_equiv(3000));
    my %wd3001 = (%wd_gbp, amount => -_GBP_equiv(3001));

    # Test that the client cannot withdraw the equivalent of EUR 3001
    throws_ok { $client->validate_payment(%wd3001) } qr/We're unable to process your withdrawal request .* GBP/,
        'Unauthed, not allowed to withdraw GBP equiv of EUR3001.';
    # mx client should be cashier locked and unwelcome
    ok $client->status->unwelcome,      'MX client is unwelcome after wihtdrawal limit is reached';
    ok $client->status->cashier_locked, 'MX client is cashier_locked after wihtdrawal limit is reached';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    ok $client->validate_payment(%wd3000), 'Unauthed, allowed to withdraw GBP equiv of EUR3000.';

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->save;
    ok $client->validate_payment(%wd3001), 'Authed, allowed to withdraw GBP equiv of EUR3001.';
    $client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $client->save;

    $client->smart_payment(%wd2500);
    my $payment      = $client->db->dbic->run(fixup => sub { $_->selectrow_hashref("SELECT * FROM payment.payment ORDER BY id DESC LIMIT 1"); });
    my $payment_time = Date::Utility->new($payment->{payment_time})->epoch;

    throws_ok { $client->validate_payment(%wd0501) } qr/We're unable to process your withdrawal request .* GBP/,
        'Unauthed, not allowed to withdraw equiv 2500 EUR then 501 making total over 3000.';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    ok $client->validate_payment(%wd0500), 'Unauthed, allowed to withdraw equiv 2500 EUR then 500 making total 3000.';

    # move forward 29 days
    set_fixed_time($payment_time + 29 * 86400);

    throws_ok { $client->validate_payment(%wd0501) } qr/We're unable to process your withdrawal request .* GBP/,
        'Unauthed, not allowed to withdraw equiv 3000 EUR then 1 more 29 days later';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    # move forward 1 day
    set_fixed_time(time + 86400 + 1);
    ok $client->validate_payment(%wd0501), 'Unauthed, allowed to withdraw equiv EUR 3000 then 3000 more 30 days later.';
};

# Test for MLT withdrawal limits
subtest 'Total EUR2000 MLT limitation.' => sub {
    plan tests => 3;
    my $client;

    subtest 'prepare client' => sub {
        $client = new_client(
            'EUR',
            broker_code => 'MLT',
            residence   => 'nl'
        );
        ok(!$client->fully_authenticated, 'client has not authenticated identity.');

        $client->smart_payment(%deposit_eur, amount => 10000);
        $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!
        ok $client->default_account->balance == 10000, 'Correct balance';
    };

    # Test for unauthenticated withdrawals
    subtest 'unauthenticated' => sub {
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -2001) }
        qr/We're unable to process your withdrawal request because it exceeds the limit of 2000\.00 EUR\./,
            'Unauthed, not allowed to withdraw EUR2001.';

        is $client->status->unwelcome,      undef, 'Only MX client is unwelcome after it exceeds limit';
        is $client->status->cashier_locked, undef, 'Only MX client is cashier_locked after it exceeds limit';

        ok $client->validate_payment(%withdrawal_eur, amount => -2000), 'Unauthed, allowed to withdraw EUR2000.';

        $client->smart_payment(%withdrawal_eur, amount => -1900);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -101) }
        qr/We're unable to process your withdrawal request because it exceeds the limit of 100\.00 EUR\./,
            'Unauthed, total withdrawal (1900+101) > EUR2000.';

        ok $client->smart_payment(%withdrawal_eur, amount => -100), 'Unauthed, allowed to withdraw total EUR (1900+100).';
        throws_ok { $client->smart_payment(%withdrawal_eur, amount => -101) } qr/You've reached the maximum withdrawal limit of 2000\.00 EUR\./,
            'withdrawal_limit_reached';

    };

    # Test for authenticated withdrawals
    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;

        ok $client->validate_payment(%withdrawal_eur, amount => -2001), 'Authed, allowed to withdraw EUR2001.';
        $client->smart_payment(%withdrawal_eur, amount => -2001);
        ok $client->validate_payment(%withdrawal_eur, amount => -2001), 'Authed, allowed to withdraw EUR (2001+2001), no limit anymore.';

        $client->set_authentication('ID_DOCUMENT', {status => 'pending'});
        $client->save;

        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -100) } qr/You've reached the maximum withdrawal limit of 2000\.00 EUR\./,
            'Unauthed, not allowed to withdraw as limit already > EUR2000';
    };
};

# Test for frozen bonuses
subtest 'Frozen bonus.' => sub {
    plan tests => 14;

    set_fixed_time('2009-09-01T15:00:00Z');    # for the purpose of creating a bet on frxUSDJPY

    (my $client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);

    my $account = $client->default_account;
    cmp_ok($account->balance, '==', 20, 'client\'s balance is USD20 initially.');

    my %wd_bonus = (%withdrawal, amount => -$account->balance);
    throws_ok { $client->validate_payment(%wd_bonus) } qr/includes frozen/, 'client not allowed to withdraw frozen bonus.';

    $client->smart_payment(%deposit, amount => 300);

    cmp_ok($account->balance, '==', 320, 'client\'s balance is USD320 after promo plus 300 credit.');

    ok $client->validate_payment(%withdrawal, amount => -300), 'client is allowed to withdraw entire non-frozen part of balance';

    throws_ok { $client->validate_payment(%withdrawal, amount => -320) } qr/includes frozen/,
        'client not allowed to withdraw funds including frozen bonus.';

    # gift was given:
    ($client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);
    $account = $client->default_account;
    $client->smart_payment(%deposit, amount => 200);

    # gift was rescinded:
    _apply_promo_amount($client, -1);
    cmp_ok($account->balance, '==', 200, 'Bonus has been rescinded.');

    lives_ok { $client->validate_payment(%withdrawal, amount => -$account->balance) } 'Full balance can be withdrawn after bonus has been rescinded.';

    # check that there are no rounding errors (SWAT-2078)
    ok 3.2 > 23.2 - 20, "Decimal arithmetic error is possible";
    ($client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);
    $account = $client->default_account;
    cmp_ok($account->balance, '==', 20, 'Client\'s balance is USD20 initially again.');

    $client->smart_payment(%deposit, amount => 3.2);
    ok $client->validate_payment(%withdrawal, amount => -3.2), 'Can withdraw an unfrozen amount that may raise a decimal arithmetic error';
};

subtest 'Payout counter' => sub {
    my $client = new_client('USD');

    is $client->get_df_payouts_count, 0, 'No pending payouts for new client';

    $client->incr_df_payouts_count('trace_id_1');
    is $client->get_df_payouts_count, 1, 'One payout is pending';

    $client->incr_df_payouts_count('trace_id_1');
    is $client->get_df_payouts_count, 1, 'dublicates doesnt count';

    $client->incr_df_payouts_count('trace_id_2');
    is $client->get_df_payouts_count, 2, 'Counts only uniq payouts';

    $client->decr_df_payouts_count('trace_id_1');
    is $client->get_df_payouts_count, 1, 'First payout is finished';

    $client->decr_df_payouts_count('trace_id_0');
    is $client->get_df_payouts_count, 1, 'Uncounted payout requests do not decrement counter';

    $client->decr_df_payouts_count('trace_id_2');
    is $client->get_df_payouts_count, 0, 'Second payout is finished';
};

# Subroutine for applying a promo code
sub _apply_promo_amount {
    my $client    = shift;
    my $direction = shift;

    my $account     = $client->default_account;
    my $pre_balance = $account->balance;

    $client->promo_code_status('CLAIM');
    my $pc = $client->client_promo_code->promotion;
    $pc->{_json} = JSON::MaybeXS->new->decode($pc->promo_code_config) || {};
    my $amount = $pc->{_json}{amount} * $direction;

    $client->smart_payment(
        currency     => $account->currency_code(),
        amount       => $amount,
        remark       => 'promo',
        payment_type => 'free_gift'
    );
    my $post_balance = $account->balance;
    cmp_ok $post_balance, '==', $pre_balance + $amount, "balance $post_balance after promo code credit";
}

# Subroutine to get the GBP equivalent of EUR
sub _GBP_equiv { sprintf '%.2f', convert_currency($_[0], 'EUR', 'GBP') }

done_testing();

