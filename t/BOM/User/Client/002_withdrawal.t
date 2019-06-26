#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Withdrawal;

use strict;
use warnings;

use Test::MockTime qw( set_fixed_time);
use Test::More;
use Test::Exception;
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

populate_exchange_rates();

my $recorded_date = Date::Utility->new;

my %new_client_details = (
    broker_code     => 'CR',
    residence       => 'br',
    client_password => 'x',
    last_name       => 'binary',
    first_name      => 'test',
    email           => 'binarytest@binary.com',
    salutation      => 'Ms',
    address_line_1  => 'ADDR 1',
    address_city    => 'Cyberjaya',
    phone           => '+60123456789',
    place_of_birth  => 'br',
    secret_question => "Mother's maiden name",
    secret_answer   => 'blah',
);

sub new_client {
    my $currency = shift;
    my $c = $user->create_client(%new_client_details, @_);
    $c->set_default_account($currency);
    $c;
}

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

my %deposit_bch    = (%deposit,    currency => 'BCH');
my %withdrawal_bch = (%withdrawal, currency => 'BCH');

my %deposit_ltc    = (%deposit,    currency => 'LTC');
my %withdrawal_ltc = (%withdrawal, currency => 'LTC');

subtest 'General' => sub {
    plan tests => 1;
    my $client = new_client('USD');

    $client->smart_payment(%deposit);
    ok($client->validate_payment(%withdrawal), 'Withdrawals available under normal conditions.');
};

# Test for disables and locks
subtest 'Client-specific' => sub {
    plan tests => 5;
    my $client = new_client('USD');

    $client->status->set('withdrawal_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/disabled/, 'Client withdrawals have been locked.';
    $client->status->clear_withdrawal_locked;

    $client->status->clear_unwelcome;
    $client->status->set('disabled', 'a-payments-clerk', '..dont like you, sorry.');
    throws_ok { $client->validate_payment(%withdrawal) } qr/disabled/, 'Client disabled.';

    $client->status->set('cashier_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client's cashier is locked/, 'Client withdrawals have been locked.';
    $client->status->clear_cashier_locked;

    $client->status->set('disabled', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client is disabled/, 'Client withdrawals have been locked.';
    $client->status->clear_disabled;

    $client->cashier_setting_password('12345');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client has set the cashier password/, 'Client cashier is locked by himself.';
    $client->cashier_setting_password('');
};

# Test for withdrawals that the exceed client's balance
subtest "withdraw vs Balance" => sub {
    plan tests => 1;
    my $client = new_client('USD');
    $client->smart_payment(%deposit);
    throws_ok { $client->validate_payment(%withdrawal, amount => -100.01) } qr/exceeds client balance/, "Withdraw more than balance";
};

# Test for CR withdrawal limits
subtest 'CR withdrawal' => sub {
    plan tests => 7;

    # CR withdrawals in USD
    subtest 'in USD, unauthenticated' => sub {
        my $client = new_client('USD');
        my $dbh    = $client->dbh;
        $client->smart_payment(%deposit, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal, amount => -10001) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD10K';
        lives_ok { $client->validate_payment(%withdrawal, amount => -10000) } 'Non-Authed CR withdrawal USD10K';

        lives_ok { $client->validate_payment(%withdrawal, amount => -9999) } 'Non-Authed CR withdrawal USD9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'first 5k withdrawal';
            throws_ok { $client->smart_payment(%withdrawal, amount => -5001) } qr/exceeds withdrawal limit \[USD 5000.00\]/,
                'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in EUR
    subtest 'in EUR, unauthenticated' => sub {
        my $client = new_client('EUR');
        my $var = $client->smart_payment(%deposit_eur, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -10001) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8411.84) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8410.84) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_eur, amount => -5000) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_eur, amount => -5001) } qr/exceeds withdrawal limit/, 'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in BTC
    subtest 'in BTC, unauthenticated' => sub {
        my $client = new_client('BTC');
        my $var = $client->smart_payment(%deposit_btc, amount => 3.00000000);
        throws_ok { $client->validate_payment(%withdrawal_btc, amount => -2) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.81818181) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.80000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_btc, amount => -0.90909090) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_btc, amount => -0.91000000) } qr/exceeds withdrawal limit/, 'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in BCH
    subtest 'in BCH, unauthenticated' => sub {
        my $client = new_client('BCH');
        $client->smart_payment(%deposit_bch, amount => 35);
        throws_ok { $client->validate_payment(%withdrawal_bch, amount => -32) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_bch, amount => -31.25000000) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_bch, amount => -31.24687500) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_bch, amount => -15.62500000) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_bch, amount => -15.62812500) } qr/exceeds withdrawal limit/, 'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in LTC
    subtest 'in LTC, unauthenticated' => sub {
        my $client = new_client('LTC');
        $client->smart_payment(%deposit_ltc, amount => 201.00000000);
        throws_ok { $client->validate_payment(%withdrawal_ltc, amount => -201.00000000) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -200.00000000) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -199.98000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_ltc, amount => -100.00000000) } 'first 5k USD withdrawal';
            throws_ok { $client->smart_payment(%withdrawal_ltc, amount => -100.02000000) } qr/exceeds withdrawal limit/,
                'total withdraw cannot > 10k';
        };
    };

    # Fully authenticated CR withdrawals - No more limit
    subtest 'fully authenticated' => sub {
        my $client = new_client('USD');
        $client->status->set('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID',);
        $client->set_authentication('ID_DOCUMENT')->status('pass');
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
        $client->status->set('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID',);
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        my $var = $client->smart_payment(%deposit_btc, amount => 0.01434048);
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -0.01434048) } 'Authed CR withdraw full BTC amount';
    };
};

# Test for MX withdrawal limits
subtest 'EUR3k over 30 days MX limitation.' => sub {
    plan tests => 11;

    my $client = new_client(
        'GBP',
        broker_code => 'MX',
        residence   => 'gb'
    );

    ok(!$client->fully_authenticated, 'client has not authenticated identity.');

    my $gbp_amount = _GBP_equiv(6200);
    $client->smart_payment(
        %deposit,
        amount   => $gbp_amount,
        currency => 'GBP'
    );
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
    throws_ok { $client->validate_payment(%wd3001) } qr/exceeds withdrawal limit \[EUR/, 'Unauthed, not allowed to withdraw GBP equiv of EUR3001.';
    # mx client should be cashier locked and unwelcome
    ok $client->status->unwelcome,      'MX client is unwelcome after wihtdrawal limit is reached';
    ok $client->status->cashier_locked, 'MX client is cashier_locked after wihtdrawal limit is reached';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    ok $client->validate_payment(%wd3000), 'Unauthed, allowed to withdraw GBP equiv of EUR3000.';

    $client->set_authentication('ID_DOCUMENT')->status('pass');
    $client->save;
    ok $client->validate_payment(%wd3001), 'Authed, allowed to withdraw GBP equiv of EUR3001.';
    $client->set_authentication('ID_DOCUMENT')->status('pending');
    $client->save;

    $client->smart_payment(%wd2500);

    throws_ok { $client->validate_payment(%wd0501) } qr/exceeds withdrawal limit \[EUR/,
        'Unauthed, not allowed to withdraw equiv EUR2500 then 501 making total over 3000.';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    ok $client->validate_payment(%wd0500), 'Unauthed, allowed to withdraw equiv EUR2500 then 500 making total 3000.';

    # move forward 29 days
    set_fixed_time(time + 29 * 86400);

    throws_ok { $client->validate_payment(%wd0501) } qr/exceeds withdrawal limit \[EUR/,
        'Unauthed, not allowed to withdraw equiv EUR3000 then 1 more 29 days later';

    # remove for further testing
    $client->status->clear_unwelcome;
    $client->status->clear_cashier_locked;

    # move forward 1 day
    set_fixed_time(time + 86400 + 1);
    ok $client->validate_payment(%wd0501), 'Unauthed, allowed to withdraw equiv EUR3000 then 3000 more 30 days later.';
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
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -2001) } qr/exceeds withdrawal limit \[EUR/,
            'Unauthed, not allowed to withdraw EUR2001.';

        is $client->status->unwelcome,      undef, 'Only MX client is unwelcome after it exceeds limit';
        is $client->status->cashier_locked, undef, 'Only MX client is cashier_locked after it exceeds limit';

        ok $client->validate_payment(%withdrawal_eur, amount => -2000), 'Unauthed, allowed to withdraw EUR2000.';

        $client->smart_payment(%withdrawal_eur, amount => -1900);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -101) } qr/exceeds withdrawal limit \[EUR/,
            'Unauthed, total withdrawal (1900+101) > EUR2000.';

        ok $client->validate_payment(%withdrawal_eur, amount => -100), 'Unauthed, allowed to withdraw total EUR (1900+100).';
    };

    # Test for authenticated withdrawals
    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;

        ok $client->validate_payment(%withdrawal_eur, amount => -2001), 'Authed, allowed to withdraw EUR2001.';
        $client->smart_payment(%withdrawal_eur, amount => -2001);
        ok $client->validate_payment(%withdrawal_eur, amount => -2001), 'Authed, allowed to withdraw EUR (2001+2001), no limit anymore.';

        $client->set_authentication('ID_DOCUMENT')->status('pending');
        $client->save;

        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -100) } qr/exceeds withdrawal limit \[EUR/,
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

