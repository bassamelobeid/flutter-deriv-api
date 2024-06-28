#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

subtest 'country=za; creates financial account with existing gaming account while real->p01_ts02 disabled' => sub {
    my $new_email = 'abcdef' . $DETAILS{email};
    my $user      = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    my $new_client = create_client(
        'CR', undef,
        {
            residence      => 'za',
            binary_user_id => $user->id,
        });
    my $m     = BOM::Platform::Token::API->new;
    my $token = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming',                                             'account_type=gaming';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'}, 'created in group real\p01_ts02\synthetic\svg_std_usd\01';

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    my $financial = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
    is $financial->{account_type}, 'financial',                                              'account_type=financial';
    is $financial->{login},        'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'}, 'created in group real\p01_ts01\financial\svg_std_usd';
    note('then call mt5 login list');
    $method = 'mt5_login_list';
    $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    note("disable real->p01_ts02 API calls.");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);
    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
    ok scalar(@$login_list) == 2, 'two accounts';
    is $login_list->[0]->{account_type},                       'real';
    is $login_list->[0]->{group},                              'real\p01_ts01\financial\svg_std_usd';
    is $login_list->[0]->{login},                              'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
    is $login_list->[0]->{server_info}{geolocation}{location}, 'Ireland', 'location Ireland';
    is $login_list->[0]->{server_info}{geolocation}{region},   'Europe',  'region Europe';

    # second account inaccessible because API call is disabled
    ok $login_list->[1]->{error}, 'inaccessible account shows error';
    is $login_list->[1]->{error}{details}{login},                              'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};
    is $login_list->[1]->{error}{message_to_client},                           'MT5 is currently unavailable. Please try again later.';
    is $login_list->[1]->{error}{details}{server_info}{geolocation}{location}, 'South Africa', 'location South Africa';
    is $login_list->[1]->{error}{details}{server_info}{geolocation}{region},   'Africa',       'region Africa';

    subtest 'test with status' => sub {
        my $mt5_id = $login_list->[0]->{login};
        $user->update_loginid_status($mt5_id, 'migrated_single_email');    # this status does not work for mt5
        $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        ok scalar(@$login_list) == 1, 'one account';
        is $login_list->[0]->{error}{details}{login}, 'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};

        $user->update_loginid_status($mt5_id, 'poa_outdated');             # this status should not filter out the account
        $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        ok scalar(@$login_list) == 2, 'two accounts again';
        is $login_list->[0]->{login},                 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
        is $login_list->[1]->{error}{details}{login}, 'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'};

    };
};

subtest 'mt5 svg migration: idv based jurisdiction selection' => sub {
    # Since we already create CR account we can reuse it
    my $client          = BOM::User::Client->new({loginid => 'CR10000'});
    my $m               = BOM::Platform::Token::API->new;
    my $token           = $m->create_token($client->loginid, 'test token');
    my $client_mock     = Test::MockModule->new('BOM::User::Client');
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');
    my $doc_mock        = Test::MockModule->new(ref($client->documents));
    my $method          = 'mt5_login_list';
    my $best_issue_date;
    $doc_mock->mock(
        'best_issue_date',
        sub {
            return Date::Utility->new($best_issue_date) if $best_issue_date;
            return undef;
        });

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    subtest 'not authenticated by IDV' => sub {
        $client_mock->mock('get_idv_status', sub { return 'none' });
        $client_mock->mock('get_poa_status', sub { return 'none' });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'not authenticated by IDV = no eligible';

        $client_mock->unmock_all;
    };

    subtest 'IDV + POA (pending)' => sub {
        $client_mock->mock('get_idv_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status', sub { return 'pending' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'IDV + POA (pending) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'IDV + POA rejected' => sub {
        $client_mock->mock('get_idv_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status', sub { return 'rejected' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'IDV + POA rejected = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'IDV + POA verified (submitted within 6 months)' => sub {
        $client_mock->mock('get_idv_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status', sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'vanuatu', 'IDV + POA verified (submitted within 6 months) = vanuatu';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef,     'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'IDV + POA verified (submitted longer than 6 months)' => sub {
        $client_mock->mock('get_idv_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status', sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->minus_months(7)->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'IDV + POA verified (submitted longer than 6 months) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'IDV with a Photo ID in the document' => sub {
        $client->set_authentication_and_status('IDV_PHOTO', {status => 'pass'});

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        ok $client->fully_authenticated, 'Fully auth';
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'IDV with a Photo ID in the document = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client_mock->unmock_all;
    };

    subtest 'IDV with Address in the document' => sub {
        $_->delete for @{$client->client_authentication_method};
        $client = BOM::User::Client->new({loginid => $client->loginid});    # avoid cache hits
        $client->set_authentication_and_status('IDV', 'test');

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        ok $client->fully_authenticated, 'Fully auth';
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'IDV with Address in the document = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client_mock->unmock_all;
    };

    subtest 'high risk' => sub {
        $client->aml_risk_classification('high');
        $client->save;
        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;

        is $login_list->[0]->{eligible_to_migrate}, undef, 'eligible to migrate is correct = none';

        $client_mock->unmock_all;
    };

    subtest 'skipping for IB account' => sub {
        $mock_async_call->mock(
            'get_user',
            sub {
                my $original_future = $mock_async_call->original('get_user')->(@_);

                my $modified_future = $original_future->then(
                    sub {
                        my ($variables) = @_;

                        $variables->{comment} = 'IB';
                        return $variables;
                    });

                return $modified_future;
            });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'skipping for IB account';
    };

    subtest 'skipping for mt5 account under -lim sub-account category' => sub {
        $mock_async_call->mock(
            'get_user',
            sub {
                my $original_future = $mock_async_call->original('get_user')->(@_);

                my $modified_future = $original_future->then(
                    sub {
                        my ($variables) = @_;

                        $variables->{group} = 'real\\p01_ts01\\financial\\svg_std-lim_usd';
                        return $variables;
                    });

                return $modified_future;
            });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'skipping for mt5 account under -lim sub-account category';
    };

    subtest 'skipping for mt5 account under -sf sub-account category' => sub {
        $mock_async_call->mock(
            'get_user',
            sub {
                my $original_future = $mock_async_call->original('get_user')->(@_);

                my $modified_future = $original_future->then(
                    sub {
                        my ($variables) = @_;

                        $variables->{group} = 'real\\p01_ts01\\all\\svg_std-sf_usd';
                        return $variables;
                    });

                return $modified_future;
            });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'skipping for mt5 account under -sf sub-account category';
    };

    $mock_async_call->unmock_all;

    subtest 'skipping for client that already have bvi account' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
        $client_mock->mock('get_idv_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status', sub { return 'pending' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[1]->{eligible_to_migrate}->{synthetic}, 'bvi', 'Should get bvi';

        my $bvi_synthetic_params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                email        => 'bvi_synthetic_' . $DETAILS{email},
                name         => $DETAILS{name},
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
                company      => 'bvi',
            },
        };
        $client->citizen('de');
        $client->status->set('crs_tin_information', 'test', 'test');
        $client->account_opening_reason('test');
        $client->tax_residence('de');
        $client->tax_identification_number('17628349405');
        my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save;
        my $result = $c->call_ok('mt5_new_account', $bvi_synthetic_params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming',                                                 'account_type=gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\bvi_std_usd'}, 'created in group real\p01_ts02\synthetic\bvi_std_usd';

        $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[2]->{eligible_to_migrate}, undef, 'skipping for client that already bvi have account';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    $mock_async_call->unmock_all;
    $client_mock->unmock_all;
};

subtest 'mt5 svg migration: onfido based jurisdiction selection' => sub {
    # Since we already create CR account we can reuse it
    my $client          = BOM::User::Client->new({loginid => 'CR10000'});
    my $m               = BOM::Platform::Token::API->new;
    my $token           = $m->create_token($client->loginid, 'test token');
    my $client_mock     = Test::MockModule->new('BOM::User::Client');
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');
    my $doc_mock        = Test::MockModule->new(ref($client->documents));
    my $method          = 'mt5_login_list';
    my $best_issue_date;
    $doc_mock->mock(
        'best_issue_date',
        sub {
            return Date::Utility->new($best_issue_date) if $best_issue_date;
            return undef;
        });

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    subtest 'not authenticated by onfido' => sub {
        $client_mock->mock('get_onfido_status', sub { return 'none' });
        $client_mock->mock('get_poa_status',    sub { return 'none' });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'not authenticated by onfido = not eligible';

        $client_mock->unmock_all;
    };

    subtest 'Onfido + POA (pending)' => sub {
        $client_mock->mock('get_onfido_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',    sub { return 'pending' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Onfido + POA (pending) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Onfido + POA rejected' => sub {
        $client_mock->mock('get_onfido_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',    sub { return 'rejected' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Onfido + POA rejected = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Onfido + POA verified (submitted within 6 months)' => sub {
        $client_mock->mock('get_onfido_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',    sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'vanuatu', 'Onfido + POA verified (submitted within 6 months) = vanuatu';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef,     'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Onfido + POA verified (submitted longer than 6 months)' => sub {
        $client_mock->mock('get_onfido_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',    sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->minus_months(7)->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Onfido + POA verified (submitted longer than 6 months) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'high risk' => sub {
        $client->aml_risk_classification('high');
        $client->save;
        $client_mock->mock('get_onfido_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',    sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'vanuatu', 'high risk = vanuatu';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef,     'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    $client_mock->unmock_all;
    $mock_async_call->unmock_all;
};

subtest 'mt5 svg migration: manual poi based jurisdiction selection' => sub {
    # Since we already create CR account we can reuse it
    my $client          = BOM::User::Client->new({loginid => 'CR10000'});
    my $m               = BOM::Platform::Token::API->new;
    my $token           = $m->create_token($client->loginid, 'test token');
    my $client_mock     = Test::MockModule->new('BOM::User::Client');
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');
    my $doc_mock        = Test::MockModule->new(ref($client->documents));
    my $method          = 'mt5_login_list';
    my $best_issue_date;
    $doc_mock->mock(
        'best_issue_date',
        sub {
            return Date::Utility->new($best_issue_date) if $best_issue_date;
            return undef;
        });

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    subtest 'not authenticated by manual' => sub {
        $client_mock->mock('get_manual_poi_status', sub { return 'none' });
        $client_mock->mock('get_poa_status',        sub { return 'none' });

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}, undef, 'not authenticated by manual = not eligible';

        $client_mock->unmock_all;
    };

    subtest 'Manual POI + POA (pending)' => sub {
        $client_mock->mock('get_manual_poi_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',        sub { return 'pending' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Manual POI + POA (pending) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Manual POI + POA rejected' => sub {
        $client_mock->mock('get_manual_poi_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',        sub { return 'rejected' });

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Manual POI + POA rejected = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Manual POI + POA verified (submitted within 6 months)' => sub {
        $client_mock->mock('get_manual_poi_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',        sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'vanuatu', 'Manual POI + POA verified (submitted within 6 months) = vanuatu';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef,     'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    subtest 'Manual POI + POA verified (submitted longer than 6 months)' => sub {
        $client_mock->mock('get_manual_poi_status', sub { return 'verified' });
        $client_mock->mock('get_poa_status',        sub { return 'verified' });
        $best_issue_date = Date::Utility->new()->minus_months(7)->epoch;

        $client->status->setnx('age_verification', 'Test', 'Test Case');
        ok $client->status->age_verification, "Age verified by other sources";

        my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
        is $login_list->[0]->{eligible_to_migrate}->{financial}, 'bvi', 'Manual POI + POA verified (submitted longer than 6 months) = bvi';
        is $login_list->[0]->{eligible_to_migrate}->{synthetic}, undef, 'Should not get synthetic';

        $client->status->clear_age_verification;
        $client_mock->unmock_all;
    };

    $client_mock->unmock_all;
    $mock_async_call->unmock_all;
};

subtest 'skip eligible to migrate flag for demo account' => sub {
    # Since we already create CR account we can reuse it
    my $client      = BOM::User::Client->new({loginid => 'CR10000'});
    my $m           = BOM::Platform::Token::API->new;
    my $token       = $m->create_token($client->loginid, 'test token');
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $method      = 'mt5_login_list';
    my $params      = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $client_mock->mock('get_idv_status', sub { return 'verified' });
    $client_mock->mock('get_poa_status', sub { return 'pending' });

    $client->status->setnx('age_verification', 'Test', 'Test Case');
    ok $client->status->age_verification, "Age verified by other sources";

    my $demo_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            email            => 'demo_' . $DETAILS{email},
            name             => $DETAILS{name},
            mainPassword     => $DETAILS{password}{main},
            leverage         => 100,
            company          => 'svg',
            mt5_account_type => 'financial',
        },
    };
    my $result = $c->call_ok('mt5_new_account', $demo_params)->has_no_error('demo account successfully created')->result;
    is $result->{account_type}, 'demo', 'demo account creation';

    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
    my ($demo_account) = grep { $_->{'group'} && $_->{'group'} =~ /demo/ } @$login_list;
    is $demo_account->{eligible_to_migrate}, undef, 'skipping for client that already bvi have account';

    $client_mock->unmock_all;
};

subtest 'mt5 white label download links assignment' => sub {

    my $client      = BOM::User::Client->new({loginid => 'CR10000'});
    my $m           = BOM::Platform::Token::API->new;
    my $token       = $m->create_token($client->loginid, 'test token');
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $method      = 'mt5_login_list';
    my $params      = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    my $real_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            email            => 'real_' . $DETAILS{email},
            name             => $DETAILS{name},
            mainPassword     => $DETAILS{password}{main},
            leverage         => 100,
            company          => 'bvi',
            mt5_account_type => 'financial',
        },
    };
    my $result = $c->call_ok('mt5_new_account', $real_params)->has_no_error('real account successfully created')->result;
    is $result->{account_type}, 'financial', 'real account creation';

    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;

    my ($real_account) = grep { $_->{'group'} && $_->{'group'} =~ /real/ } @$login_list;

    is(
        $real_account->{white_label}->{download_links}->{windows},
        'https://download.mql5.com/cdn/web/22698/mt5/derivsvg5setup.exe',
        'Windows link is correctly assigned'
    );
    is(
        $real_account->{white_label}->{download_links}->{ios},
        'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
        'iOS link is correctly assigned'
    );
    is(
        $real_account->{white_label}->{download_links}->{android},
        'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
        'Android link is correctly assigned'
    );
    is($real_account->{white_label}->{notification}, 0, 'Notification is correctly assigned');

    $client_mock->unmock_all;
};

subtest 'mt5 white label links assignment' => sub {

    my $client      = BOM::User::Client->new({loginid => 'CR10000'});
    my $m           = BOM::Platform::Token::API->new;
    my $token       = $m->create_token($client->loginid, 'test token');
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $method      = 'mt5_login_list';
    my $params      = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;

    my ($real_account) = grep { $_->{'group'} && $_->{'group'} =~ /real/ } @$login_list;

    is(
        $real_account->{white_label_links}->{windows},
        'https://download.mql5.com/cdn/web/22698/mt5/derivsvg5setup.exe',
        'Windows link is correctly assigned'
    );
    is(
        $real_account->{white_label_links}->{ios},
        'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
        'iOS link is correctly assigned'
    );
    is(
        $real_account->{white_label_links}->{android},
        'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
        'Android link is correctly assigned'
    );

    is($real_account->{white_label_links}->{webtrader_url}, 'https://mt5-real01-web-svg.deriv.com/terminal', 'Webtrader link is correctly assigned');

    $client_mock->unmock_all;
};

subtest 'mt5 login list return boolean rights' => sub {

    # Setup a test user
    my $user = BOM::User->create(
        email    => $DETAILS{email},
        password => 's3kr1t',
    );
    $user->update_trading_password($DETAILS{password}{main});

    my $test_client = create_client('CR');
    $test_client->email($DETAILS{email});
    $test_client->set_default_account('USD');
    $test_client->binary_user_id($user->id);

    $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $test_client->save;

    $user->add_client($test_client);

    my $m     = BOM::Platform::Token::API->new;
    my $token = $m->create_token($test_client->loginid, 'test token');

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $DETAILS{email},
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    my $r = $c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account')->result;

    my $expected_rights = {
        api             => 1,
        api_deprecated  => 0,
        confirmed       => 0,
        enabled         => 1,
        exclude_reports => 0,
        expert          => 1,
        investor        => 0,
        otp_enabled     => 0,
        password_change => 1,
        push            => 0,
        readonly        => 0,
        reports         => 1,
        reset_pass      => 0,
        sponsored       => 0,
        technical       => 0,
        trade_disabled  => 0,
        trailing        => 1,
    };

    my $method = 'mt5_login_list';
    $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
    is_deeply($login_list->[0]->{rights}, $expected_rights, 'Rights are correctly assigned');

};

done_testing();
