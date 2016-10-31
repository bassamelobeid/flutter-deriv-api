use strict;
use warnings;
use utf8;

use Test::Most;
use Test::Mojo;
use Test::BOM::RPC::Client;
use Test::MockModule;
use Format::Util::Numbers qw(roundnear);
use YAML::XS qw(LoadFile);

use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Product::RiskProfile;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'get_limits';
my $params = {token => '12345'};

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

subtest 'CR' => sub {
    my $email  = 'raunak@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');

    $client->email($email);
    $client->save;
    my $loginid = $client->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    my $limits = LoadFile(File::ShareDir::dist_file('LandingCompany', 'payment_limits.yml'))->withdrawal_limits->costarica;

    subtest 'expected errors' => sub {
        $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'invalid token');
        $client->set_status('disabled', 1, 'test');
        $client->save;
        $params->{token} = $token;
        $c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'invalid token');
        $client->clr_status('disabled');
        $client->set_status('cashier_locked', 1, 'test');
        $client->save;
        $c->call_ok($method, $params)->has_error->error_message_is('Sorry, this feature is not available.', 'invalid token');

        $client->clr_status('cashier_locked');
        $client->save;
    };

    subtest 'unauthenticated' => sub {
        my $expected_result = {
            'account_balance'                     => $client->get_limit_for_account_balance,
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => $client->get_limit_for_payout,
            'market_specific'                     => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->for_days,
            'num_of_days_limit'                   => $limits->limit_for_days,
            'lifetime_limit'                      => $limits->lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0',
            'withdrawal_since_inception_monetary' => '0',
            'remainder'                           => roundnear(0.01, $limits->lifetime_limit),
        };
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        $client->smart_payment(%deposit);
        # withdraw USD 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal);

        $expected_result->{withdrawal_for_x_days_monetary}      = roundnear(0.01, $withdraw_amount);
        $expected_result->{withdrawal_since_inception_monetary} = roundnear(0.01, $withdraw_amount);
        $expected_result->{remainder}                           = roundnear(0.01, $limits->lifetime_limit - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        my $expected_result = {
            'account_balance'   => $client->get_limit_for_account_balance,
            'open_positions'    => $client->get_limit_for_open_positions,
            'payout'            => $client->get_limit_for_payout,
            'market_specific'   => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'       => $limits->for_days,
            'num_of_days_limit' => '99999999',
            'lifetime_limit'    => '99999999',
        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };

    subtest 'Add expired doc' => sub {
        #add an expired document
        my ($doc) = $client->add_client_authentication_document({
            document_type              => "Passport",
            document_format            => "PDF",
            document_path              => '/tmp/test.pdf',
            expiration_date            => '2008-10-10',
            authentication_method_code => 'ID_DOCUMENT'
        });
        $client->save;
        $c->call_ok($method, $params)->has_error->error_message_is('Sorry, this feature is not available.', 'invalid token');
    };
};

subtest 'JP' => sub {
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

    my $limits = LoadFile(File::ShareDir::dist_file('LandingCompany', 'payment_limits.yml'))->withdrawal_limits->japan;

    subtest 'unauthenticated' => sub {
        my $expected_result = {
            'account_balance'                     => $client->get_limit_for_account_balance,
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => $client->get_limit_for_payout,
            'market_specific'                     => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->for_days,
            'num_of_days_limit'                   => $limits->limit_for_days,
            'lifetime_limit'                      => $limits->lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0',
            'withdrawal_since_inception_monetary' => '0',
            'remainder'                           => roundnear(0.01, $limits->lifetime_limit),
        };
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        $client->smart_payment(%deposit, currency => 'JPY');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # withdraw JPY 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'JPY');

        $expected_result->{'withdrawal_for_x_days_monetary'}      = roundnear(0.01, $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = roundnear(0.01, $withdraw_amount);
        $expected_result->{'remainder'}                           = roundnear(0.01, $limits->lifetime_limit - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        my $expected_result = {
            'account_balance'   => $client->get_limit_for_account_balance,
            'open_positions'    => $client->get_limit_for_open_positions,
            'payout'            => $client->get_limit_for_payout,
            'market_specific'   => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'       => $limits->for_days,
            'num_of_days_limit' => '99999999',
            'lifetime_limit'    => '99999999',
        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

subtest 'MLT' => sub {
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

    my $limits = LoadFile(File::ShareDir::dist_file('LandingCompany', 'payment_limits.yml'))->withdrawal_limits->malta;

    subtest 'unauthenticated' => sub {
        my $expected_result = {
            'account_balance'                     => $client->get_limit_for_account_balance,
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => $client->get_limit_for_payout,
            'market_specific'                     => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->for_days,
            'num_of_days_limit'                   => $limits->limit_for_days,
            'lifetime_limit'                      => $limits->lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0',
            'withdrawal_since_inception_monetary' => '0',
            'remainder'                           => roundnear(0.01, $limits->lifetime_limit),
        };
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        $client->smart_payment(%deposit, currency => 'EUR');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        $expected_result->{'withdrawal_for_x_days_monetary'}      = roundnear(0.01, $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = roundnear(0.01, $withdraw_amount);
        $expected_result->{'remainder'}                           = roundnear(0.01, $limits->lifetime_limit - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        my $expected_result = {
            'account_balance'   => $client->get_limit_for_account_balance,
            'open_positions'    => $client->get_limit_for_open_positions,
            'payout'            => $client->get_limit_for_payout,
            'market_specific'   => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'       => $limits->for_days,
            'num_of_days_limit' => '99999999',
            'lifetime_limit'    => '99999999',
        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

subtest 'MX' => sub {
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

    my $limits = LoadFile(File::ShareDir::dist_file('LandingCompany', 'payment_limits.yml'))->withdrawal_limits->iom;

    subtest 'unauthenticated' => sub {
        my $expected_result = {
            'account_balance'                     => $client->get_limit_for_account_balance,
            'open_positions'                      => $client->get_limit_for_open_positions,
            'payout'                              => $client->get_limit_for_payout,
            'market_specific'                     => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'                         => $limits->for_days,
            'num_of_days_limit'                   => $limits->limit_for_days,
            'lifetime_limit'                      => $limits->lifetime_limit,
            'withdrawal_for_x_days_monetary'      => '0',
            'withdrawal_since_inception_monetary' => '0',
            'remainder'                           => roundnear(0.01, $limits->limit_for_days),
        };
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');

        $client->smart_payment(%deposit, currency => 'EUR');
        $client->clr_status('cashier_locked');    # first-deposit will cause this in non-CR clients!
        $client->save;

        # withdraw EUR 1000
        my $withdraw_amount = 1000;
        $client->smart_payment(%withdrawal, currency => 'EUR');

        $expected_result->{'withdrawal_for_x_days_monetary'}      = roundnear(0.01, $withdraw_amount);
        $expected_result->{'withdrawal_since_inception_monetary'} = roundnear(0.01, $withdraw_amount);
        $expected_result->{'remainder'}                           = roundnear(0.01, $limits->limit_for_days - $withdraw_amount);

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok');
    };

    subtest 'authenticated' => sub {
        $client->set_authentication('ID_DOCUMENT')->status('pass');
        $client->save;
        my $expected_result = {
            'account_balance'   => $client->get_limit_for_account_balance,
            'open_positions'    => $client->get_limit_for_open_positions,
            'payout'            => $client->get_limit_for_payout,
            'market_specific'   => BOM::Product::RiskProfile::get_current_profile_definitions($client),
            'num_of_days'       => $limits->for_days,
            'num_of_days_limit' => '99999999',
            'lifetime_limit'    => '99999999',
        };

        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is ok for fully authenticated client');
    };
};

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

