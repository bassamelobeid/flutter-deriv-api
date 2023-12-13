use strict;
use warnings;
use utf8;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::Deep;
use YAML::XS qw(LoadFile);

use Format::Util::Numbers qw/formatnumber financialrounding/;
use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::Database::Model::OAuth;
use BOM::Platform::RiskProfile;
use Email::Stuffer::TestLinks;
use BOM::Config;
use BOM::Config::Runtime;

use ExchangeRates::CurrencyConverter qw/in_usd convert_currency/;

my $c              = BOM::Test::RPC::QueueClient->new();
my $payment_limits = BOM::Config::payment_limits();
my $params         = {token => '12345'};

# Mocked currency converter to imitate currency conversion for CR accounts
my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mocked_CurrencyConverter->mock(
    'in_usd',
    sub {
        my $price         = shift;
        my $from_currency = shift;

        $from_currency eq 'EUR' and return 1.1888 * $price;
        $from_currency eq 'GBP' and return 1.3333 * $price;
        $from_currency eq 'JPY' and return 0.0089 * $price;
        $from_currency eq 'BTC' and return 5500 * $price;
        $from_currency eq 'USD' and return 1 * $price;
        return 0;
    });

$mocked_CurrencyConverter->mock(offer_to_clients => 1);

my %withdrawal = (
    currency     => 'USD',
    amount       => -1000,
    payment_type => 'external_cashier',
    remark       => 'test withdrawal'
);

my %deposit = (
    currency     => 'USD',
    amount       => 11000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my $transfer_config = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts;

$transfer_config->limits->crypto_to_crypto(100);
$transfer_config->limits->crypto_to_fiat(200);
$transfer_config->limits->fiat_to_crypto(300);

# Test for CR accounts which use USD as the currency
subtest 'CR - USD' => sub {

    # Initialise a CR test account and email and set USD as the currency
    my $email  = 'test-cr-usd@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'dsd32e23ewef',
    );
    $client->set_default_account('USD');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    # Load limits for CR, which is in USD
    my $limits = $payment_limits->{withdrawal_limits}->{svg};

    # Test for expected errors, such as invalid tokens
    subtest 'expected errors' => sub {
        $c->call_ok('get_limits', $params)->has_error->error_message_is('The token is invalid.', 'invalid token');
        $client->status->set('disabled', 1, 'test');
        $params->{token} = $token;
        $c->call_ok('get_limits', $params)->has_error->error_message_is('This account is unavailable.', 'invalid token');
        $client->status->clear_disabled;
        $client->status->set('cashier_locked', 1, 'test');

        my $account_limit = $c->call_ok('get_limits', $params)->has_no_error->result->{account_balance};
        if ($client->landing_company->unlimited_balance) {
            is($account_limit, undef, "No limits for cashier locked clients");
        } else {
            ok $account_limit, "Got limits for cashier locked clients";
        }

        $client->status->clear_cashier_locked;
    };

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {

        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'USD', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'USD', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'USD', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price', 'USD', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price', 'USD', $limits->{lifetime_limit}),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
            'lifetime_transfers'                  => {
                crypto_to_fiat => {
                    allowed   => num(200),
                    available => num(200),
                },
                fiat_to_crypto => {
                    allowed   => num(300),
                    available => num(300),
                },
            }};

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'initial expected result',);

        # Deposit USD 11000
        $client->smart_payment(%deposit);

        # Withdraw USD 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal);

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{withdrawal_for_x_days_monetary}      = formatnumber('price', 'USD', $withdraw_amount);
        $expected_result->{withdrawal_since_inception_monetary} = formatnumber('price', 'USD', $withdraw_amount);
        $expected_result->{remainder}                           = formatnumber('price', 'USD', $limits->{lifetime_limit} - $withdraw_amount);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'expected result after transcctions',);
    };

    # Set expected results to reflect withdrawn amount of USD 1000
    my $expected_auth_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0,
            source_type                => 'official',
        },
        'account_balance' => $client->landing_company->unlimited_balance
        ? undef
        : formatnumber('amount', 'USD', $client->get_limit_for_account_balance),
        'open_positions'                      => $client->get_limit_for_open_positions,
        'payout'                              => formatnumber('price', 'USD', $client->get_limit_for_payout),
        'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
        'num_of_days'                         => $limits->{for_days},
        'num_of_days_limit'                   => formatnumber('price', 'USD', 99999999),
        'lifetime_limit'                      => formatnumber('price', 'USD', 99999999),
        'withdrawal_since_inception_monetary' => '1000.00',
        'withdrawal_for_x_days_monetary'      => '1000.00',
        'remainder'                           => formatnumber('price', 'USD', 99998999),
        'daily_transfers'                     => ignore(),                                 # daily limits tests are in 22_daily_transfer_limit.t
        'daily_cumulative_amount_transfers'   => ignore(),
        'lifetime_transfers'                  => {
            crypto_to_fiat => {
                allowed   => num(200),
                available => num(200),
            },
            fiat_to_crypto => {
                allowed   => num(300),
                available => num(300),
            },
        }};

    subtest 'skip_authentication' => sub {
        my $mock_lc = Test::MockModule->new('LandingCompany');
        $mock_lc->mock('skip_authentication', sub { 1 });

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_auth_result, 'result is ok for non-KYC landing company',);
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;
        delete $expected_auth_result->{lifetime_transfers};

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_auth_result, 'result is ok for fully authenticated client',);
    };

    # Test for expired documents
    subtest 'Add expired doc' => sub {
        # Add an expired document
        my ($doc) = $client->add_client_authentication_document({
            document_type              => "Passport",
            document_format            => "PDF",
            document_path              => '/tmp/test.pdf',
            expiration_date            => '2008-10-10',
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => 'CE114E4501D2F4E2DCEA3E17B546F339'
        });
        $client->save;

        my $account_limit = $c->call_ok('get_limits', $params)->has_no_error->result->{account_balance};
        if ($client->landing_company->unlimited_balance) {
            is($account_limit, undef, "No limits for clients");
        } else {
            ok $account_limit, "Got limits for client with expired docs";
        }
    };
};

# Test for CR accounts which use EUR as the currency
subtest 'CR-EUR' => sub {

    # Initialise a CR test account and email and set USD as the currency
    my $email  = 'test-cr-eur@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'dsd32e23ewef',
    );
    $client->set_default_account('EUR');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for CR, which is in USD, then convert to EUR
    my $limits         = $payment_limits->{withdrawal_limits}->{svg};
    my $limit_for_days = formatnumber('price', 'EUR', convert_currency($limits->{limit_for_days}, 'USD', 'EUR'));
    my $lifetime_limit = formatnumber('price', 'EUR', convert_currency($limits->{lifetime_limit}, 'USD', 'EUR'));

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => $lifetime_limit,
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
            'lifetime_transfers'                  => {
                crypto_to_fiat => {
                    allowed   => financialrounding('amount', 'EUR', convert_currency(200, 'USD', 'EUR')),
                    available => financialrounding('amount', 'EUR', convert_currency(200, 'USD', 'EUR')),
                },
                fiat_to_crypto => {
                    allowed   => financialrounding('amount', 'EUR', convert_currency(300, 'USD', 'EUR')),
                    available => financialrounding('amount', 'EUR', convert_currency(300, 'USD', 'EUR')),
                },
            },
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $lifetime_limit - $withdraw_amount);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
    };

    # Convert limits from 99999999 USD to EUR
    $limit_for_days = formatnumber('price', 'EUR', convert_currency(99999999, 'USD', 'EUR'));
    $lifetime_limit = formatnumber('price', 'EUR', convert_currency(99999999, 'USD', 'EUR'));

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;
        # Set expected results to reflect withdrawn amount of EUR 1000
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price', 'EUR', $lifetime_limit - 1000),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
    };
};

# Test for CR accounts which use BTC as the currency
subtest 'CR-BTC' => sub {
    # Initialise a CR test account and email and set BTC as the currency
    my $email  = 'test-cr-BTC@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'dsd32e23ewef',
    );
    $client->set_default_account('BTC');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for CR, which is in USD, then convert to BTC
    my $limits         = $payment_limits->{withdrawal_limits}->{svg};
    my $limit_for_days = formatnumber('price', 'BTC', convert_currency($limits->{limit_for_days}, 'USD', 'BTC'));
    my $lifetime_limit = formatnumber('price', 'BTC', convert_currency($limits->{lifetime_limit}, 'USD', 'BTC'));

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'BTC', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'BTC', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0.00000000',
            'withdrawal_since_inception_monetary' => '0.00000000',
            'remainder'                           => $lifetime_limit,
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
            'lifetime_transfers'                  => {
                crypto_to_crypto => {
                    allowed   => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
                    available => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
                },
                crypto_to_fiat => {
                    allowed   => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
                    available => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
                },
                fiat_to_crypto => {
                    allowed   => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
                    available => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
                },
            },
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

        # Deposit BTC 2.00000000
        $client->smart_payment(
            %deposit,
            currency => 'BTC',
            amount   => 2
        );
        $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

        # Withdraw BTC 1.00000000
        my $withdraw_amount = 1;
        $client->smart_payment(
            %withdrawal,
            currency => 'BTC',
            amount   => -1
        );

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'BTC', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'BTC', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'BTC', $lifetime_limit - $withdraw_amount);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
    };

    # Convert limits from 99999999 USD to BTC
    $limit_for_days = formatnumber('price', 'BTC', convert_currency(99999999, 'USD', 'BTC'));
    $lifetime_limit = formatnumber('price', 'BTC', convert_currency(99999999, 'USD', 'BTC'));

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;
        # Set expected results to reflect withdrawn amount of BTC 1.00000000
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'BTC', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'BTC', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_since_inception_monetary' => '1.00000000',
            'withdrawal_for_x_days_monetary'      => '1.00000000',
            'remainder'                           => formatnumber('price', 'BTC', $lifetime_limit - 1),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
    };
};

# Test for MLT accounts which use EUR as the currency
subtest 'MLT' => sub {
    # Initialise a MLT test account and email and set EUR as the currency
    my $email  = 'test-mlt@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MLT',
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'dsd32e23ewef',
    );

    $client->set_default_account('EUR');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for MLT, which is in EUR
    my $limits = $payment_limits->{withdrawal_limits}->{malta};

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{lifetime_limit} - $withdraw_amount);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;
        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
            'lifetime_limit'                      => formatnumber('price', 'EUR', 99999999),
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price', 'EUR', 99998999),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
    };
};

# Test for MX accounts which use EUR as the currency
subtest 'MX' => sub {
    # Initialise a MX test account and email and set EUR as the currency
    my $email  = 'test-mx@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MX',
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $email,
        password => 'dsd32e23ewef',
    );
    $client->set_default_account('EUR');
    my $mocked_landing = Test::MockModule->new(ref($client->landing_company));
    $mocked_landing->mock('is_currency_legal', sub { 1 });

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for MX, which is in EUR
    my $limits = $payment_limits->{withdrawal_limits}->{iom};

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price', 'EUR', $limits->{limit_for_days}),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{limit_for_days} - $withdraw_amount);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->save;
        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
            'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price', 'EUR', 99998999),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
    };

    subtest 'limits with withdrawal_reversals' => sub {
        $client->smart_payment(
            %withdrawal,
            amount   => -100,
            currency => 'EUR'
        );

        my $expected_result = {
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            'account_balance' => $client->landing_company->unlimited_balance
            ? undef
            : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
            'lifetime_limit'                      => formatnumber('price', 'EUR', 99999999),
            'withdrawal_since_inception_monetary' => '1100.00',
            'withdrawal_for_x_days_monetary'      => '1100.00',
            'remainder'                           => formatnumber('price', 'EUR', 99998899),
            'daily_transfers'                     => ignore(),
            'daily_cumulative_amount_transfers'   => ignore(),
        };

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'correct withdrawal limits',);

        # perform a reversal
        $client->payment_doughflow(
            %withdrawal,
            transaction_type => 'withdrawal_reversal',
            amount           => 50,
            payment_fee      => -1,
            payment_method   => 'BigPay',
            trace_id         => 104,
            currency         => 'EUR',
            remark           => 'x'
        );

        $expected_result->{withdrawal_since_inception_monetary} = '1050.00';
        $expected_result->{withdrawal_for_x_days_monetary}      = '1050.00';
        $expected_result->{remainder}                           = formatnumber('price', 'EUR', 99998949);

        cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'correct withdrawal limits after 50 EUR reversal',);
    }
};

subtest 'VRTC' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email       => 'vrtc@test.com',
        broker_code => 'VRTC',
    });
    $client->account('USD');

    BOM::User->create(
        email    => $client->email,
        password => 'x',
    )->add_client($client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, {stash => ignore()}, 'empty limits for VRTC',);
};

subtest 'Daily limits' => sub {
    $transfer_config->daily_cumulative_limit->enable(1);

    my $amt = 5;
    for my $limit (qw(virtual between_accounts between_wallets MT5 dxtrade derivez ctrader dtrade)) {
        $transfer_config->limits->$limit($amt);
        $transfer_config->daily_cumulative_limit->$limit($amt * 100);
        $amt++;
    }

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

    my $user = BOM::User->create(
        email    => 'dailylimits@test.com',
        password => 'x',
    );
    my %clients;

    subtest 'Virtual wallet' => sub {
        $clients{vrw} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            email       => $user->email,
            broker_code => 'VRW',
        });
        $user->add_client($clients{vrw});

        $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $clients{vrw}->loginid);

        $user->daily_transfer_incr_count('virtual', $user->id);
        $user->daily_transfer_incr_amount(10, 'virtual', $user->id);

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            {
                stash => ignore(),
            },
            'No daily limits if no account yet',
        );

        $clients{vrw}->account('USD');

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled => bool(1),
                        virtual => {
                            allowed   => '500.00',
                            available => '490.00',
                        },
                    },
                    daily_transfers => {
                        virtual => {
                            allowed   => 5,
                            available => 4,
                        }
                    },
                }
            ),
            'VRW gets virtual limit only',
        );

        $transfer_config->daily_cumulative_limit->enable(0);
        cmp_ok $c->call_ok('get_limits', $params)->result->{daily_cumulative_amount_transfers}{enabled}, '==', 0,
            $transfer_config->daily_cumulative_limit->enable(1);

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled => bool(1),
                        virtual => {
                            allowed   => '500.00',
                            available => '490.00',
                        }
                    },
                    daily_transfers => {
                        virtual => {
                            allowed   => 5,
                            available => 4,
                        }
                    },
                }
            ),
            'Count limit hidden when limit <= 0',
        );

        $transfer_config->daily_cumulative_limit->virtual(0);

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled => bool(1),
                    },
                    daily_transfers => {
                        virtual => {
                            allowed   => 5,
                            available => 4,
                        }
                    },
                }
            ),
            'Cumulative limit hidden when limit <= 0',
        );

        $transfer_config->daily_cumulative_limit->virtual(500);
        $transfer_config->limits->virtual(0);

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled => bool(1),
                        virtual => {
                            allowed   => '500.00',
                            available => '490.00',
                        }
                    },
                    daily_transfers => {},
                }
            ),
            'Count limit hidden when limit <= 0',
        );
    };

    subtest 'legacy CR' => sub {
        $clients{legacy} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            email       => $user->email,
            broker_code => 'CR',
        });
        $user->add_client($clients{legacy});
        $clients{legacy}->account('USD');

        $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $clients{legacy}->loginid);

        for my $type (qw(internal wallet MT5 dxtrade derivez ctrader)) {
            $user->daily_transfer_incr_count($type, $user->id);
            $user->daily_transfer_incr_amount(10, $type, $user->id);
        }

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled  => bool(1),
                        internal => {
                            allowed   => '600.00',
                            available => '590.00',
                        },
                        mt5 => {
                            allowed   => '800.00',
                            available => '790.00',
                        },
                        dxtrade => {
                            allowed   => '900.00',
                            available => '890.00',
                        },
                        derivez => {
                            allowed   => '1000.00',
                            available => '990.00',
                        },
                        ctrader => {
                            allowed   => '1100.00',
                            available => '1090.00',
                        },
                    },
                    daily_transfers => {
                        internal => {
                            allowed   => 6,
                            available => 5,
                        },
                        mt5 => {
                            allowed   => 8,
                            available => 7,
                        },
                        dxtrade => {
                            allowed   => 9,
                            available => 8,
                        },
                        derivez => {
                            allowed   => 10,
                            available => 9,
                        },
                        ctrader => {
                            allowed   => 11,
                            available => 10,
                        },
                    },
                }
            ),
            'got expected daily limits'
        );
    };

    subtest 'CRW wallet' => sub {
        $clients{crw} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            email       => $user->email,
            broker_code => 'CRW',
        });
        $user->add_client($clients{crw});
        $clients{crw}->account('USD');

        $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $clients{crw}->loginid);

        for my $type (qw(dtrade MT5 dxtrade derivez ctrader)) {
            $user->daily_transfer_incr_count($type, $clients{crw}->loginid) for (1 .. 2);
            $user->daily_transfer_incr_amount(15, $type, $clients{crw}->loginid);
        }

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled  => bool(1),
                        internal => {
                            allowed   => '600.00',
                            available => '590.00',
                        },
                        wallets => {
                            allowed   => '700.00',
                            available => '690.00',
                        },
                        mt5 => {
                            allowed   => '800.00',
                            available => '785.00',
                        },
                        dxtrade => {
                            allowed   => '900.00',
                            available => '885.00',
                        },
                        derivez => {
                            allowed   => '1000.00',
                            available => '985.00',
                        },
                        ctrader => {
                            allowed   => '1100.00',
                            available => '1085.00',
                        },
                        dtrade => {
                            allowed   => '1200.00',
                            available => '1185.00',
                        },
                    },
                    daily_transfers => {
                        internal => {
                            allowed   => 6,
                            available => 5,
                        },
                        wallets => {
                            allowed   => 7,
                            available => 6,
                        },
                        mt5 => {
                            allowed   => 8,
                            available => 6,
                        },
                        dxtrade => {
                            allowed   => 9,
                            available => 7,
                        },
                        derivez => {
                            allowed   => 10,
                            available => 8,
                        },
                        ctrader => {
                            allowed   => 11,
                            available => 9,
                        },
                        dtrade => {
                            allowed   => 12,
                            available => 10,
                        },
                    }}
            ),
            'got expected daily limits'
        );
    };

    subtest 'CR standard' => sub {
        $clients{standard} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            email        => $user->email,
            broker_code  => 'CR',
            account_type => 'standard',
        });
        $clients{standard}->account('USD');
        $user->add_client($clients{standard});
        $user->link_wallet_to_trading_account({client_id => $clients{standard}->loginid, wallet_id => $clients{crw}->loginid});

        $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $clients{standard}->loginid);

        cmp_deeply(
            $c->call_ok('get_limits', $params)->has_no_error->result,
            superhashof({
                    daily_cumulative_amount_transfers => {
                        enabled => bool(1),
                        dtrade  => {
                            allowed   => '1200.00',
                            available => '1185.00',
                        }
                    },
                    daily_transfers => {
                        dtrade => {
                            allowed   => 12,
                            available => 10,
                        }
                    },
                }
            ),
            'got expected daily limits'
        );
    };
};

subtest 'lifetime transfer limits' => sub {

    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_usd->account('USD');
    BOM::Test::Helper::Client::top_up($client_usd, 'USD', 1000);
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', email => $client_usd->email});
    $client_btc->account('BTC');
    my $user = BOM::User->create(
        email    => $client_usd->email,
        password => 'x'
    );
    $user->add_client($client_usd);
    $user->add_client($client_btc);
    my $token_usd = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_usd->loginid);
    my $token_btc = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_btc->loginid);

    $params->{token} = $token_usd;
    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_fiat => {
                allowed   => num(200),
                available => num(200),
            },
            fiat_to_crypto => {
                allowed   => num(300),
                available => num(300),
            },
        },
        'new usd account'
    );

    $params->{token} = $token_btc;
    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
            },
            crypto_to_fiat => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
            },
            fiat_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
            },
        },
        'new btc account'
    );

    $params->{token} = $token_usd;
    $params->{args}  = {
        account_from => $client_usd->loginid,
        account_to   => $client_btc->loginid,
        amount       => 50,
        currency     => 'USD',
    };

    $c->call_ok('transfer_between_accounts', $params)->has_no_error('transfer from fiat to crypto');

    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_fiat => {
                allowed   => num(200),
                available => num(150),
            },
            fiat_to_crypto => {
                allowed   => num(300),
                available => num(250),
            },
        },
        'usd account limits reduced after transfer'
    );

    $params->{token} = $token_btc;
    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
            },
            crypto_to_fiat => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
            },
            fiat_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
            },
        },
        'btc account limits not reduced after transfer'
    );

    my $amount = financialrounding('amount', 'BTC', convert_currency(10, 'USD', 'BTC'));

    $params->{token} = $token_btc;
    $params->{args}  = {
        account_from => $client_btc->loginid,
        account_to   => $client_usd->loginid,
        amount       => $amount,
        currency     => 'BTC',
    };

    $c->call_ok('transfer_between_accounts', $params)->has_no_error('transfer from crypto to fiat');

    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(100, 'USD', 'BTC') - $amount),
            },
            crypto_to_fiat => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(200, 'USD', 'BTC') - $amount),
            },
            fiat_to_crypto => {
                allowed   => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC')),
                available => financialrounding('amount', 'BTC', convert_currency(300, 'USD', 'BTC') - $amount),
            },
        },
        'btc account limits reduced after transfer'
    );

    $params->{token} = $token_usd;
    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_fiat => {
                allowed   => num(200),
                available => num(150),
            },
            fiat_to_crypto => {
                allowed   => num(300),
                available => num(250),
            },
        },
        'usd account limits not reduced after transfer'
    );

    $client_usd->account->add_payment_transaction({
        amount               => -900,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $client_usd->loginid,    # db function filters by this
        remark               => 'x',
    });

    cmp_ok $client_usd->lifetime_internal_withdrawals, '==', 950, 'client now has 950 lifetime internal withdrawals';

    cmp_deeply(
        $c->call_ok('get_limits', $params)->result->{lifetime_transfers},
        {
            crypto_to_fiat => {
                allowed   => num(200),
                available => num(0),
            },
            fiat_to_crypto => {
                allowed   => num(300),
                available => num(0),
            },
        },
        'limits floor at zero when exceeded'
    );

};

done_testing();
