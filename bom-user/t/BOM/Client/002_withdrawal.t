#!/etc/rmg/bin/perl
package t::Validation::Transaction::Payment::Withdrawal;

use strict;
use warnings;

use Test::MockTime qw( set_fixed_time);
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;
use File::Spec;
use JSON::MaybeXS;
use Date::Utility;
use Cache::RedisDB;

use ExchangeRates::CurrencyConverter           qw/in_usd convert_currency/;
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates           qw/populate_exchange_rates/;
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

    is_deeply exception { $client->validate_payment(%withdrawal) },
        {
        code              => 'WithdrawalLockedStatus',
        params            => [],
        message_to_client => 'Your account is locked for withdrawals.',
        },
        'Client withdrawals have been locked.';

    $client->status->clear_withdrawal_locked;

    $client->status->clear_unwelcome;
    $client->status->set('disabled', 'a-payments-clerk', '..dont like you, sorry.');

    is_deeply exception { $client->validate_payment(%withdrawal) },
        {
        code              => 'DisabledAccount',
        params            => ['CR10001'],
        message_to_client => 'Your account is disabled.',
        },
        'Client disabled';

    $client->status->set('cashier_locked', 'calum', 'reason?');

    is_deeply exception { $client->validate_payment(%withdrawal) },
        {
        code              => 'CashierLocked',
        params            => [],
        message_to_client => 'Your cashier is locked.',
        },
        'Cashier locked, withdrawals not allowed';

    $client->status->clear_cashier_locked;

    $client->status->setnx('disabled', 'calum', 'reason?');

    is_deeply exception { $client->validate_payment(%withdrawal) },
        {
        code              => 'DisabledAccount',
        params            => ['CR10001'],
        message_to_client => 'Your account is disabled.',
        },
        'Client disabled, withdrawals not allowed';

    $client->status->clear_disabled;
};

# Test for withdrawals that the exceed client's balance
subtest "withdraw vs Balance" => sub {
    plan tests => 1;
    my $client = new_client('USD');
    $client->smart_payment(%deposit);

    is_deeply exception { $client->validate_payment(%withdrawal, amount => -100.01) },
        {
        code              => 'AmountExceedsBalance',
        params            => ['100.01', 'USD', '100.00',],
        message_to_client => 'Withdrawal amount [100.01 USD] exceeds client balance [100.00 USD].',
        },
        'Withdraw more than balance';
};

subtest 'withdraw vs empty account' => sub {
    plan tests => 1;
    my $client = new_client('USD');

    is_deeply exception { $client->validate_payment(%withdrawal, amount => -100.01) },
        {
        code              => 'NoBalance',
        params            => [$client->loginid],
        message_to_client => 'This transaction cannot be done because your ' . $client->loginid . ' account has zero balance.',
        },
        'Withdraw with empty account';
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

        is_deeply exception { $client->validate_payment(%withdrawal, amount => -10001) },
            {
            code              => 'WithdrawalLimit',
            params            => ['10000.00', 'USD',],
            message_to_client =>
                "We're unable to process your withdrawal request because it exceeds the limit of 10000.00 USD. Please authenticate your account before proceeding with this withdrawal.",
            },
            'Non-Authed CR withdrawal greater than USD10K';

        lives_ok { $client->validate_payment(%withdrawal, amount => -10000) } 'Non-Authed CR withdrawal USD10K';

        lives_ok { $client->validate_payment(%withdrawal, amount => -9999) } 'Non-Authed CR withdrawal USD9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'first 5k withdrawal';

            is_deeply exception { $client->smart_payment(%withdrawal, amount => -5001) },
                {
                code              => 'WithdrawalLimit',
                params            => ['5000.00', 'USD',],
                message_to_client =>
                    "We're unable to process your withdrawal request because it exceeds the limit of 5000.00 USD. Please authenticate your account before proceeding with this withdrawal."
                },
                'total withdraw cannot > 10k';

            lives_ok { $client->smart_payment(%withdrawal, amount => -5000) } 'second 5k withdrawal';
            is($emitted{$client->loginid}, 'withdrawal_limit_reached', 'An event is emitted to set the client as needs_action');

            is_deeply exception { $client->validate_payment(%withdrawal, amount => -100) },
                {
                code              => 'WithdrawalLimitReached',
                params            => ['10000.00', 'USD',],
                message_to_client =>
                    "You've reached the maximum withdrawal limit of 10000.00 USD. Please authenticate your account before proceeding with this withdrawal.",
                },
                'withdrawal_limit_reached';
        };

        $mock_events->unmock_all();
    };

    # CR withdrawals in EUR
    subtest 'in EUR, unauthenticated' => sub {
        my $client = new_client('EUR');
        my $var    = $client->smart_payment(%deposit_eur, amount => 10500);

        cmp_deeply exception { $client->validate_payment(%withdrawal_eur, amount => -10001) },
            {
            code              => 'WithdrawalLimit',
            params            => [re(qr/[\d\.]+/), 'EUR',],
            message_to_client => re(
                qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ EUR. Please authenticate your account before proceeding with this withdrawal./
            ),
            },
            'Non-Authed CR withdrawal greater than USD 10K';

        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8411.84) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_eur, amount => -8410.84) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_eur, amount => -5000) } 'first 5k USD withdrawal';

            cmp_deeply exception { $client->smart_payment(%withdrawal_eur, amount => -5001) },
                {
                code              => 'WithdrawalLimit',
                params            => [re(qr/[\d\.]+/), 'EUR',],
                message_to_client => re(
                    qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ EUR. Please authenticate your account before proceeding with this withdrawal./
                )
                },
                'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in BTC
    subtest 'in BTC, unauthenticated' => sub {
        my $client = new_client('BTC');
        my $var    = $client->smart_payment(%deposit_btc, amount => 3.00000000);

        cmp_deeply exception { $client->validate_payment(%withdrawal_btc, amount => -2) },
            {
            code              => 'WithdrawalLimit',
            params            => [re(qr/[\d\.]+/), 'BTC',],
            message_to_client => re(
                qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ BTC. Please authenticate your account before proceeding with this withdrawal./
            ),
            },
            'Non-Authed CR withdrawal greater than USD 10K';

        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.81818181) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -1.80000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_btc, amount => -0.90909090) } 'first 5k USD withdrawal';

            cmp_deeply exception { $client->smart_payment(%withdrawal_btc, amount => -0.91000000) },
                {
                code              => 'WithdrawalLimit',
                params            => [re(qr/[\d\.]+/), 'BTC',],
                message_to_client => re(
                    qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ BTC. Please authenticate your account before proceeding with this withdrawal./
                ),
                },
                'total withdraw cannot > 10k';
        };
    };

    # CR withdrawals in LTC
    subtest 'in LTC, unauthenticated' => sub {
        my $client = new_client('LTC');
        $client->smart_payment(%deposit_ltc, amount => 201.00000000);

        cmp_deeply exception { $client->validate_payment(%withdrawal_ltc, amount => -201.00000000) },
            {
            code              => 'WithdrawalLimit',
            params            => [re(qr/[\d\.]+/), 'LTC',],
            message_to_client => re(
                qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ LTC. Please authenticate your account before proceeding with this withdrawal./
            ),
            },
            'Non-Authed CR withdrawal greater than USD 10K';

        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -200.00000000) } 'Non-Authed CR withdrawal USD 10K';
        lives_ok { $client->validate_payment(%withdrawal_ltc, amount => -199.98000000) } 'Non-Authed CR withdrawal USD 9999';

        subtest 'perform withdraw' => sub {
            lives_ok { $client->smart_payment(%withdrawal_ltc, amount => -100.00000000) } 'first 5k USD withdrawal';

            cmp_deeply exception { $client->smart_payment(%withdrawal_ltc, amount => -100.02000000) },
                {
                code              => 'WithdrawalLimit',
                params            => [re(qr/[\d\.]+/), 'LTC',],
                message_to_client => re(
                    qr/We're unable to process your withdrawal request because it exceeds the limit of [\d\.]+ LTC. Please authenticate your account before proceeding with this withdrawal./
                ),
                },
                'total withdraw cannot > 10k';
        };
    };

    # Fully authenticated CR withdrawals - No more limit
    subtest 'fully authenticated' => sub {
        my $client = new_client('USD');
        $client->status->set('age_verification', 'system', 'test',);
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
        $client->status->setnx('age_verification', 'system', 'testD');
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        my $var = $client->smart_payment(%deposit_btc, amount => 0.01434048);
        lives_ok { $client->validate_payment(%withdrawal_btc, amount => -0.01434048) } 'Authed CR withdraw full BTC amount';
        $client->set_authentication('ID_DOCUMENT', {status => 'pending'});
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
    is_deeply exception { $client->validate_payment(%wd_bonus) },
        {
        code              => 'AmountExceedsUnfrozenBalance',
        params            => ['USD', '20.00', '20.00', '20.00',],
        message_to_client => "Withdrawal is 20.00 USD but balance 20.00 includes frozen bonus 20.00.",
        },
        'client not allowed to withdraw frozen bonus.';

    $client->smart_payment(%deposit, amount => 300);

    cmp_ok($account->balance, '==', 320, 'client\'s balance is USD320 after promo plus 300 credit.');

    ok $client->validate_payment(%withdrawal, amount => -300), 'client is allowed to withdraw entire non-frozen part of balance';

    is_deeply exception { $client->validate_payment(%withdrawal, amount => -320) },
        {
        code              => 'AmountExceedsUnfrozenBalance',
        params            => ['USD', '320.00', '320.00', '20.00',],
        message_to_client => "Withdrawal is 320.00 USD but balance 320.00 includes frozen bonus 20.00.",
        },
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

subtest "Validate Payment" => sub {
    plan tests => 1;
    my $client             = new_client('BTC');
    my $mocked_rule_engine = Test::MockModule->new('BOM::Rules::Engine');
    $mocked_rule_engine->mock(
        verify_action => sub {
            die {
                error_code => 'DuplicateAccount',
                params     => [],
                rule       => 'client.check_duplicate_account',
            };
        });

    is_deeply exception { $client->validate_payment(%withdrawal_btc, amount => -2) },
        {
        code              => 'DuplicateAccount',
        params            => [],
        message_to_client => "An error occurred while processing your request. Please try again later.",
        },
        'Default error message for error not defined in error mapping';
    $mocked_rule_engine->unmock_all();
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

