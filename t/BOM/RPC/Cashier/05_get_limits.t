use strict;
use warnings;
use utf8;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use YAML::XS qw(LoadFile);

use Format::Util::Numbers qw/formatnumber/;
use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::Client;
use BOM::Database::Model::OAuth;
use BOM::Platform::RiskProfile;

use Postgres::FeedDB::CurrencyConverter qw/in_USD amount_from_to_currency/;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'get_limits';
my $params = {token => '12345'};

# Mocked currency converter to imitate currency conversion for CR accounts
my $mocked_CurrencyConverter = Test::MockModule->new('Postgres::FeedDB::CurrencyConverter');
$mocked_CurrencyConverter->mock(
    'in_USD',
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

# Test for CR accounts which use USD as the currency
subtest 'CR - USD' => sub {

    # Initialise a CR test account and email and set USD as the currency
    my $email  = 'test-cr-usd@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    # Load limits for CR, which is in USD
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{costarica};

    # Test for expected errors, such as invalid tokens
    subtest 'expected errors' => sub {
        $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'invalid token');
        $client->set_status('disabled', 1, 'test');
        $client->save;
        $params->{token} = $token;
        $c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'invalid token');
        $client->clr_status('disabled');
        $client->set_status('cashier_locked', 1, 'test');
        $client->save;
        ok $c->call_ok($method, $params)->has_no_error->result->{account_balance}, "Got limits for cashier locked clients";

        $client->clr_status('cashier_locked');
        $client->save;
    };

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {

        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'USD', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'USD', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'USD', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price',  'USD', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price',  'USD', $limits->{lifetime_limit}),
            'payout_per_symbol_and_contract_type' => '20000.00',
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}};
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit USD 11000
        $client->smart_payment(%deposit);

        # Withdraw USD 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal);

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{withdrawal_for_x_days_monetary}      = formatnumber('price', 'USD', $withdraw_amount);
        $expected_result->{withdrawal_since_inception_monetary} = formatnumber('price', 'USD', $withdraw_amount);
        $expected_result->{remainder}                           = formatnumber('price', 'USD', $limits->{lifetime_limit} - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;

        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'USD', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'USD', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price',  'USD', 99999999),
            'lifetime_limit'                      => formatnumber('price',  'USD', 99999999),
            'payout_per_symbol_and_contract_type' => '20000.00',
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price',  'USD', 99998999),
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}

        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };

    # Test for expired documents
    subtest 'Add expired doc' => sub {
        # Add an expired document
        my ($doc) = $client->add_client_authentication_document({
            document_type              => "Passport",
            document_format            => "PDF",
            document_path              => '/tmp/test.pdf',
            expiration_date            => '2008-10-10',
            authentication_method_code => 'ID_DOCUMENT'
        });
        $client->save;
        ok $c->call_ok($method, $params)->has_no_error->result->{account_balance}, "Got limits for client with expired docs";
    };
};

# Test for CR accounts which use EUR as the currency
subtest 'CR-EUR' => sub {

    # Initialise a CR test account and email and set USD as the currency
    my $email  = 'test-cr-eur@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('EUR');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for CR, which is in USD, then convert to EUR
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{costarica};
    my $limit_for_days = formatnumber('price', 'EUR', amount_from_to_currency($limits->{limit_for_days}, 'USD', 'EUR'));
    my $lifetime_limit = formatnumber('price', 'EUR', amount_from_to_currency($limits->{lifetime_limit}, 'USD', 'EUR'));

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => $lifetime_limit,
            'payout_per_symbol_and_contract_type' => '20000.00',
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}};
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $lifetime_limit - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Convert limits from 99999999 USD to EUR
    $limit_for_days = formatnumber('price', 'EUR', amount_from_to_currency(99999999, 'USD', 'EUR'));
    $lifetime_limit = formatnumber('price', 'EUR', amount_from_to_currency(99999999, 'USD', 'EUR'));

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        # Set expected results to reflect withdrawn amount of EUR 1000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'payout_per_symbol_and_contract_type' => '20000.00',
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price',  'EUR', $lifetime_limit - 1000),
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}};

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

# Test for CR accounts which use BTC as the currency
subtest 'CR-BTC' => sub {
    # Initialise a CR test account and email and set BTC as the currency
    my $email  = 'test-cr-BTC@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('BTC');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for CR, which is in USD, then convert to BTC
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{costarica};
    my $limit_for_days = formatnumber('price', 'BTC', amount_from_to_currency($limits->{limit_for_days}, 'USD', 'BTC'));
    my $lifetime_limit = formatnumber('price', 'BTC', amount_from_to_currency($limits->{lifetime_limit}, 'USD', 'BTC'));

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'BTC', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'BTC', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0.00000000',
            'withdrawal_since_inception_monetary' => '0.00000000',
            'remainder'                           => $lifetime_limit,
            'payout_per_symbol_and_contract_type' => '2.00000000',
            'payout_per_symbol'                   => {
                atm     => '2.00000000',
                non_atm => {
                    less_than_seven_days => '1.00000000',
                    more_than_seven_days => '2.00000000',
                }}};
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit BTC 2.00000000
        $client->smart_payment(
            %deposit,
            currency => 'BTC',
            amount   => 2
        );
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

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

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Convert limits from 99999999 USD to BTC
    $limit_for_days = formatnumber('price', 'BTC', amount_from_to_currency(99999999, 'USD', 'BTC'));
    $lifetime_limit = formatnumber('price', 'BTC', amount_from_to_currency(99999999, 'USD', 'BTC'));

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        # Set expected results to reflect withdrawn amount of BTC 1.00000000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'BTC', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'BTC', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => $limit_for_days,
            'lifetime_limit'                      => $lifetime_limit,
            'payout_per_symbol_and_contract_type' => '2.00000000',
            'withdrawal_since_inception_monetary' => '1.00000000',
            'withdrawal_for_x_days_monetary'      => '1.00000000',
            'remainder'                           => formatnumber('price',  'BTC', $lifetime_limit - 1),
            'payout_per_symbol'                   => {
                atm     => '2.00000000',
                non_atm => {
                    less_than_seven_days => '1.00000000',
                    more_than_seven_days => '2.00000000',
                }}};

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

# Test for JP accounts which use JPY as the currency
subtest 'JP' => sub {
    # Initialise a JP test account and email and set JPY as the currency
    my $email  = 'test-jp@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'JP',
    });
    $client->set_default_account('JPY');

    $client->residence('jp');
    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    $params->{token} = $token;

    # Load limits for JPY, which is in JPY
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{japan};

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'JPY', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'JPY', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => formatnumber('price', 'JPY', $limits->{for_days}),
            'num_of_days_limit'                   => formatnumber('price', 'JPY', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price',  'JPY', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => 0,
            'withdrawal_since_inception_monetary' => 0,
            'remainder'                           => formatnumber('price',  'JPY', $limits->{lifetime_limit}),
            'payout_per_symbol_and_contract_type' => 400000,
            'payout_per_symbol'                   => {
                non_atm => {
                    less_than_seven_days => 200000,
                    more_than_seven_days => 200000,
                }}};

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit JPY 11000
        $client->smart_payment(%deposit, currency => 'JPY');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # Withdraw JPY 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'JPY');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'JPY', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'JPY', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'JPY', $limits->{lifetime_limit} - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'JPY', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'JPY', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'JPY', 99999999),
            'lifetime_limit'                      => formatnumber('price',  'JPY', 99999999),
            'payout_per_symbol_and_contract_type' => 400000,
            'withdrawal_since_inception_monetary' => 1000,
            'withdrawal_for_x_days_monetary'      => 1000,
            'remainder'                           => formatnumber('price',  'JPY', 99998999),
            'payout_per_symbol'                   => {
                non_atm => {
                    less_than_seven_days => 200000,
                    more_than_seven_days => 200000,
                }}

        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

# Test for MLT accounts which use EUR as the currency
subtest 'MLT' => sub {
    # Initialise a MLT test account and email and set EUR as the currency
    my $email  = 'test-mlt@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client->set_default_account('EUR');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for MLT, which is in EUR
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{malta};

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price',  'EUR', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price',  'EUR', $limits->{lifetime_limit}),
            payout_per_symbol_and_contract_type   => '20000.00',
        };
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{lifetime_limit} - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
            'lifetime_limit'                      => formatnumber('price',  'EUR', 99999999),
            'payout_per_symbol_and_contract_type' => '20000.00',
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price',  'EUR', 99998999),
        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

# Test for MX accounts which use EUR as the currency
subtest 'MX' => sub {
    # Initialise a MX test account and email and set EUR as the currency
    my $email  = 'test-mlt@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    $client->set_default_account('EUR');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $params->{token} = $token;

    # Load limits for MX, which is in EUR
    my $limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'))->{withdrawal_limits}->{iom};

    # Test for unauthenticated accounts
    subtest 'unauthenticated' => sub {
        # Set expected results for accounts that have not had withdrawals yet
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
            'lifetime_limit'                      => formatnumber('price',  'EUR', $limits->{lifetime_limit}),
            'withdrawal_for_x_days_monetary'      => '0.00',
            'withdrawal_since_inception_monetary' => '0.00',
            'remainder'                           => formatnumber('price',  'EUR', $limits->{limit_for_days}),
            payout_per_symbol_and_contract_type   => '20000.00',
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}};
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        # Deposit EUR 11000
        $client->smart_payment(%deposit, currency => 'EUR');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # Withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        # After withdrawal, change withdrawn amount and remainder
        $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
        $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{limit_for_days} - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    # Test for authenticated accounts
    subtest 'authenticated' => sub {
        # Set client status to authenticated and save
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        # Set expected results to reflect withdrawn amount of USD 1000
        my $expected_result = {
            'account_balance'                     => formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => formatnumber('price',  'EUR', $client->get_limit_for_payout),
            'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->{for_days},
            'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
            'lifetime_limit'                      => formatnumber('price',  'EUR', $limits->{lifetime_limit}),
            'payout_per_symbol_and_contract_type' => '20000.00',
            'withdrawal_since_inception_monetary' => '1000.00',
            'withdrawal_for_x_days_monetary'      => '1000.00',
            'remainder'                           => formatnumber('price',  'EUR', 99998999),
            'payout_per_symbol'                   => {
                atm     => '10000.00',
                non_atm => {
                    less_than_seven_days => '3000.00',
                    more_than_seven_days => '10000.00',
                }}};

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

# Test for VR accounts
subtest "VR no get_limits" => sub {
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $email = 'raunak@binary.com';
    $client_vr->email($email);
    $client_vr->save;

    my ($token_vr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    $params->{token} = $token_vr;
    $c->call_ok($method, $params)->has_error->error_message_is('Sorry, this feature is not available.', 'invalid token');
};

done_testing();

