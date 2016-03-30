#!/usr/bin/perl
package t::Validation::Transaction::Payment::Withdrawal;

use strict;
use warnings;
use Test::MockTime qw( set_fixed_time);
use Test::More;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::Product;

initialize_realtime_ticks_db;
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
    secret_question => "Mother's maiden name",
    secret_answer   => 'blah',
);

sub new_client {
    my $currency = shift;
    my $c = BOM::Platform::Client->register_and_return_new_client({%new_client_details, @_});
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

subtest 'General' => sub {
    plan tests => 2;
    my $client = new_client('USD');

    $client->smart_payment(%deposit);
    ok($client->validate_payment(%withdrawal), 'Withdrawals available under normal conditions.');

    BOM::Platform::Runtime->instance->app_config->system->suspend->payments(1);
    throws_ok { $client->validate_payment(%withdrawal) } qr/suspended/, 'Withdrawals unavailable when payments suspended.';

    BOM::Platform::Runtime->instance->app_config->system->suspend->payments(0);
};

subtest 'Client-specific' => sub {
    plan tests => 5;
    my $client = new_client('USD');

    $client->set_status('withdrawal_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/disabled/, 'Client withdrawals have been locked.';
    $client->clr_status('withdrawal_locked');

    $client->clr_status('unwelcome');
    $client->set_status('disabled', 'a-payments-clerk', '..dont like you, sorry.');
    $client->save;
    throws_ok { $client->validate_payment(%withdrawal) } qr/disabled/, 'Client disabled.';

    $client->set_status('cashier_locked', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client's cashier is locked/, 'Client withdrawals have been locked.';
    $client->clr_status('cashier_locked');

    $client->set_status('disabled', 'calum', 'reason?');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client is disabled/, 'Client withdrawals have been locked.';
    $client->clr_status('disabled');

    $client->cashier_setting_password('12345');
    throws_ok { $client->validate_payment(%withdrawal) } qr/Client has set the cashier password/, 'Client cashier is locked by himself.';
    $client->cashier_setting_password('');
};

subtest "withdraw vs Balance" => sub {
    plan tests => 1;
    my $client = new_client('USD');
    $client->smart_payment(%deposit);
    throws_ok { $client->validate_payment(%withdrawal, amount => -100.01) } qr/exceeds client balance/, "Withdraw more than balance";
};

subtest 'CR withdrawal' => sub {
    plan tests => 3;

    subtest 'in USD, unauthenticated' => sub {
        my $client = new_client('USD');
        $client->smart_payment(%deposit, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal, amount => -10001) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than USD10K';
        throws_ok { $client->validate_payment(%withdrawal, amount => -10000) } qr/exceeds withdrawal limit/, 'Non-Authed CR withdrawal USD10K';
        lives_ok { $client->validate_payment(%withdrawal, amount => -9999) } 'Non-Authed CR withdrawal USD9999';
    };

    subtest 'in EUR, unauthenticated' => sub {
        my $client = new_client('EUR');
        $client->smart_payment(%deposit_eur, amount => 10500);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -10001) } qr/exceeds withdrawal limit/,
            'Non-Authed CR withdrawal greater than EUR 10K';
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -10000) } qr/exceeds withdrawal limit/, 'Non-Authed CR withdrawal EUR 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -9999) } 'Non-Authed CR withdrawal EUR 9999';
    };

    subtest 'fully authenticated' => sub {
        my $client = new_client('USD');
        $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
        $client->set_authentication('ID_192')->status('pass');
        $client->save;
        $client->smart_payment(%deposit, amount => 10500);
        lives_ok { $client->validate_payment(%withdrawal, amount => -10000) } 'Authed CR withdrawal no more than USD10K';
        lives_ok { $client->validate_payment(%withdrawal, amount => -10001) } 'Authed CR withdrawal more than USD10K';
    };
};

subtest 'JP withdrawal' => sub {
    plan tests => 2;
    my %deposit_jpy    = (%deposit,    currency => 'JPY');
    my %withdrawal_jpy = (%withdrawal, currency => 'JPY');

    subtest 'unauthenticated' => sub {
        my $client = new_client(
            'JPY',
            broker_code => 'JP',
            residence   => 'jp'
        );
        $client->smart_payment(%deposit_jpy, amount => 1100000);
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        throws_ok { $client->validate_payment(%withdrawal_jpy, amount => -1000001) } qr/exceeds withdrawal limit/,
            'Non-Authed JP withdrawal greater than JPY 1,000,000';
        throws_ok { $client->validate_payment(%withdrawal_jpy, amount => -1000000) } qr/exceeds withdrawal limit/,
            'Non-Authed JP withdrawal JPY 1,000,000';
        lives_ok { $client->validate_payment(%withdrawal_jpy, amount => -999999) } 'Non-Authed JP withdrawal JPY 999,999';
    };

    subtest 'fully authenticated' => sub {
        my $client = new_client(
            'JPY',
            broker_code => 'JP',
            residence   => 'jp'
        );

        $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
        $client->set_authentication('ID_192')->status('pass');
        $client->save;
        $client->smart_payment(%deposit_jpy, amount => 1100000);
        lives_ok { $client->validate_payment(%withdrawal_jpy, amount => -999999) } 'Authed JP withdrawal no more than JPY 1,000,000';
        lives_ok { $client->validate_payment(%withdrawal_jpy, amount => -1000001) } 'Authed JP withdrawal more than JPY 1,000,000';
    };
};

subtest 'EUR3k over 30 days MX limitation.' => sub {
    plan tests => 9;

    my $client = new_client(
        'GBP',
        broker_code => 'MX',
        residence   => 'gb'
    );

    ok(!$client->client_fully_authenticated, 'client has not authenticated identity.');

    my $gbp_amount = _GBP_equiv(6200);
    $client->smart_payment(
        %deposit,
        amount   => $gbp_amount,
        currency => 'GBP'
    );
    $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
    $client->save;

    ok $client->default_account->load->balance == $gbp_amount,
        'Successfully credited client; no other amount has been credited to GBP account segment.';

    my %wd_gbp = (
        %withdrawal,
        currency => 'GBP',
        amount   => 0
    );

    my %wd0500 = (%wd_gbp, amount => -_GBP_equiv(500));
    my %wd0501 = (%wd_gbp, amount => -_GBP_equiv(501));
    my %wd2500 = (%wd_gbp, amount => -_GBP_equiv(2500));
    my %wd3000 = (%wd_gbp, amount => -_GBP_equiv(3000));
    my %wd3001 = (%wd_gbp, amount => -_GBP_equiv(3001));

    throws_ok { $client->validate_payment(%wd3001) } qr/exceeds withdrawal limit \[EUR/, 'Unauthed, not allowed to withdraw GBP equiv of EUR3001.';

    ok $client->validate_payment(%wd3000), 'Unauthed, allowed to withdraw GBP equiv of EUR3000.';

    $client->set_authentication('ID_192')->status('pass');
    $client->save;
    ok $client->validate_payment(%wd3001), 'Authed, allowed to withdraw GBP equiv of EUR3001.';
    $client->set_authentication('ID_192')->status('pending');
    $client->save;

    $client->smart_payment(%wd2500);

    throws_ok { $client->validate_payment(%wd0501) } qr/exceeds withdrawal limit \[EUR/,
        'Unauthed, not allowed to withdraw equiv EUR2500 then 501 making total over 3000.';

    ok $client->validate_payment(%wd0500), 'Unauthed, allowed to withdraw equiv EUR2500 then 500 making total 3000.';

    # move forward 29 days
    set_fixed_time(time + 29 * 86400);

    throws_ok { $client->validate_payment(%wd0501) } qr/exceeds withdrawal limit \[EUR/,
        'Unauthed, not allowed to withdraw equiv EUR3000 then 1 more 29 days later';

    # move forward 1 day
    set_fixed_time(time + 86400 + 1);
    ok $client->validate_payment(%wd0501), 'Unauthed, allowed to withdraw equiv EUR3000 then 3000 more 30 days later.';
};

subtest 'Total EUR2300 MLT limitation.' => sub {
    plan tests => 3;
    my $client;

    subtest 'prepare client' => sub {
        $client = new_client(
            'EUR',
            broker_code => 'MLT',
            residence   => 'nl'
        );
        ok(!$client->client_fully_authenticated, 'client has not authenticated identity.');

        $client->smart_payment(%deposit_eur, amount => 10000);
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;
        ok $client->default_account->load->balance == 10000, 'Correct balance';
    };

    subtest 'unauthenticated' => sub {
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -2301) } qr/exceeds withdrawal limit \[EUR/,
            'Unauthed, not allowed to withdraw EUR2301.';
        ok $client->validate_payment(%withdrawal_eur, amount => -2300), 'Unauthed, allowed to withdraw EUR2300.';

        $client->smart_payment(%withdrawal_eur, amount => -2000);
        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -301) } qr/exceeds withdrawal limit \[EUR/,
            'Unauthed, total withdrawal (2000+301) > EUR2300.';
        ok $client->validate_payment(%withdrawal_eur, amount => -300), 'Unauthed, allowed to withdraw total EUR (2000+300).';
    };

    subtest 'authenticated' => sub {
        $client->set_authentication('ID_192')->status('pass');
        $client->save;

        ok $client->validate_payment(%withdrawal_eur, amount => -2301), 'Authed, allowed to withdraw EUR2301.';
        $client->smart_payment(%withdrawal_eur, amount => -2301);
        ok $client->validate_payment(%withdrawal_eur, amount => -2301), 'Authed, allowed to withdraw EUR (2301+2301), no limit anymore.';

        $client->set_authentication('ID_192')->status('pending');
        $client->save;

        throws_ok { $client->validate_payment(%withdrawal_eur, amount => -100) } qr/exceeds withdrawal limit \[EUR/,
            'Unauthed, not allowed to withdraw as limit already > EUR2300';
    };
};

subtest 'Frozen bonus.' => sub {
    plan tests => 16;

    set_fixed_time('2009-09-01T15:00:00Z');    # for the purpose of creating a bet on frxUSDJPY

    (my $client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);

    my $account = $client->default_account;
    cmp_ok($account->load->balance, '==', 20, 'client\'s balance is USD20 initially.');

    my %wd_bonus = (%withdrawal, amount => -$account->balance);
    throws_ok { $client->validate_payment(%wd_bonus) } qr/includes frozen/, 'client not allowed to withdraw frozen bonus.';

    $client->smart_payment(%deposit, amount => 300);

    cmp_ok($account->load->balance, '==', 320, 'client\'s balance is USD320 after promo plus 300 credit.');

    ok $client->validate_payment(%withdrawal, amount => -300), 'client is allowed to withdraw entire non-frozen part of balance';

    throws_ok { $client->validate_payment(%withdrawal, amount => -320) } qr/includes frozen/,
        'client not allowed to withdraw funds including frozen bonus.';

    # test turnover requirement:
    set_fixed_time('2009-09-01T15:05:00Z');
    BOM::Test::Data::Utility::Product::client_buy_bet($client, 'USD', 100);

    throws_ok { $client->validate_payment(%withdrawal, amount => -$account->load->balance) } qr/includes frozen/,
        'client not allowed to withdraw frozen bonus while turnover insufficient';

    set_fixed_time('2009-09-01T15:10:00Z');

    $client->smart_payment(%deposit, amount => 300);

    BOM::Test::Data::Utility::Product::client_buy_bet($client, 'USD', 401);    # pushes client over turnover threshold

    ok $client->validate_payment(%withdrawal, amount => -$account->load->balance),
        'client is allowed to withdraw full amount after turnover requirements are met.';

    # gift was given:
    ($client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);
    $account = $client->default_account;
    $client->smart_payment(%deposit, amount => 200);

    # gift was rescinded:
    _apply_promo_amount($client, -1);
    cmp_ok($account->load->balance, '==', 200, 'Bonus has been rescinded.');

    lives_ok { $client->validate_payment(%withdrawal, amount => -$account->load->balance) }
    'Full balance can be withdrawn after bonus has been rescinded.';

    # check that there are no rounding errors (SWAT-2078)
    ok 3.2 > 23.2 - 20, "Decimal arithmetic error is possible";
    ($client = new_client('USD'))->promo_code('BOM2009');
    _apply_promo_amount($client, 1);
    $account = $client->default_account;
    cmp_ok($account->load->balance, '==', 20, 'Client\'s balance is USD20 initially again.');

    $client->smart_payment(%deposit, amount => 3.2);
    ok $client->validate_payment(%withdrawal, amount => -3.2), 'Can withdraw an unfrozen amount that may raise a decimal arithmetic error';
};

sub _apply_promo_amount {
    my $client    = shift;
    my $direction = shift;

    my $account     = $client->default_account;
    my $pre_balance = $account->load->balance;

    $client->promo_code_status('CLAIM');
    my $pc = $client->client_promo_code->promotion;
    $pc->{_json} = JSON::from_json($pc->promo_code_config) || {};
    my $amount = $pc->{_json}{amount} * $direction;

    $client->smart_payment(
        currency     => $account->currency_code,
        amount       => $amount,
        remark       => 'promo',
        payment_type => 'free_gift'
    );
    my $post_balance = $account->load->balance;
    cmp_ok $post_balance, '==', $pre_balance + $amount, "balance $post_balance after promo code credit";
}

sub _GBP_equiv { sprintf '%.2f', amount_from_to_currency($_[0], 'EUR', 'GBP') }

done_testing();

