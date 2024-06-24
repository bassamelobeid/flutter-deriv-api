use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use BOM::User::Onfido;
use BOM::Config::Redis;
use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

subtest 'Onfido country code' => sub {
    my $customer = BOM::Test::Customer->create({
            email          => BOM::Test::Customer->get_random_email_address(),
            password       => BOM::User::Password::hashpw('abc123'),
            email_verified => 1,
            account_type   => 'binary',
            residence      => 'br',
        },
        [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);

    my $client = $customer->get_client_object('CR');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'Emptiness' => sub {
        $client->place_of_birth('');
        $client->residence('');
        $client->save;

        ok !$client->residence,      'Empty residence';
        ok !$client->place_of_birth, 'Empty POB';

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        # Note for this legacy scenario we strip down the country_code altogether from the response

        ok !exists($res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{country_code}), 'Country code is not reported';
    };

    subtest 'Valid country code' => sub {
        $client->place_of_birth('br');
        $client->residence('br');
        $client->save;

        is $client->residence,      'br', 'BR residence';
        is $client->place_of_birth, 'br', 'BR POB';

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        is $res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{country_code}, 'BRA', 'Expected country code found';
    };
};

subtest 'POI Attempts' => sub {
    subtest 'No POI attempts' => sub {
        my $user = BOM::User->create(
            email    => 'poi+attempts@deriv.com',
            password => 'poi_attempts_test'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            binary_user_id => $user->id
        });

        $user->add_client($client_cr);
        $client_cr->binary_user_id($user->id);
        $client_cr->save;

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
        $t->await::authorize({authorize => $token});

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);
        cmp_deeply $res->{get_account_status}->{authentication}->{attempts},
            {
            count   => 0,
            history => [],
            latest  => undef,
            },
            'expected result for empty history';
    };

    subtest 'IDV attempts' => sub {
        my $user = BOM::User->create(
            email    => 'poi+attempts+idv@deriv.com',
            password => 'poi_attempts_idv_test'
        );

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            binary_user_id => $user->id
        });

        $user->add_client($client_cr);
        $client_cr->binary_user_id($user->id);
        $client_cr->save;

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
        $t->await::authorize({authorize => $token});

        my $doc_id_1;
        my $document;
        my $idv_model = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

        lives_ok {
            $document = $idv_model->add_document({
                issuing_country => 'zw',
                number          => '00005000A00',
                type            => 'national_id',
                expiration_date => '2099-01-01'
            });
            $doc_id_1 = $document->{id};
            $idv_model->update_document_check({
                document_id => $doc_id_1,
                status      => 'failed',
                messages    => ['REPORT_UNAVAILABLE'],
                provider    => 'smile_identity'
            });
        }
        'first client document added and updated successfully';

        my $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        my $expected_count   = 1;
        my $count            = $res->{get_account_status}->{authentication}->{attempts}->{count};
        my $report_available = $res->{get_account_status}->{authentication}->{identity}->{services}->{idv}->{report_available};

        is $count, $expected_count, 'expected count=1 for 1 attempt';
        ok !$report_available, 'report is not available for REPORT_UNAVAILABLE in status messages';

        my $expected_latest_attempt_1 = {
            id            => $doc_id_1,
            status        => 'rejected',
            service       => 'idv',
            country_code  => 'zw',
            document_type => 'national_id',
        };

        my $latest_attempt = $res->{get_account_status}->{authentication}->{attempts}->{latest};
        delete($latest_attempt->{timestamp});

        cmp_deeply $latest_attempt, $expected_latest_attempt_1, 'expected latest IDV attempt';

        my $history = $res->{get_account_status}->{authentication}->{attempts}->{history};
        @$history = map { delete $_->{timestamp}; $_ } @$history;

        my $expected_history = [$expected_latest_attempt_1];
        cmp_deeply $history, $expected_history, 'expected history of IDV attempts';

        my $doc_id_2;
        lives_ok {
            $document = $idv_model->add_document({
                issuing_country => 'zw',
                number          => '12300000A00',
                type            => 'national_id',
                expiration_date => '2089-01-02'
            });
            $doc_id_2 = $document->{id};
            $idv_model->update_document_check({
                document_id => $doc_id_2,
                status      => 'verified',
                messages    => [],
                provider    => 'smile_identity'
            });
        }
        'second client document added and updated successfully';

        $res = $t->await::get_account_status({get_account_status => 1});
        test_schema('get_account_status', $res);

        $expected_count = 2;
        $count          = $res->{get_account_status}->{authentication}->{attempts}->{count};

        is $count, $expected_count, 'expected count=2 for 2 attempts';

        my $expected_latest_attempt_2 = {
            id            => $doc_id_2,
            status        => 'verified',
            service       => 'idv',
            country_code  => 'zw',
            document_type => 'national_id',
        };

        $latest_attempt = $res->{get_account_status}->{authentication}->{attempts}->{latest};
        delete($latest_attempt->{timestamp});

        cmp_deeply $latest_attempt, $expected_latest_attempt_2, 'expected latest IDV attempt after second attempt';

        $history  = $res->{get_account_status}->{authentication}->{attempts}->{history};
        @$history = map { delete $_->{timestamp}; $_ } @$history;

        $expected_history = [$expected_latest_attempt_2, $expected_latest_attempt_1];
        cmp_deeply $history, $expected_history, 'expected history of IDV attempts';
    };
};

subtest 'Proof of ownership' => sub {
    my $customer = BOM::Test::Customer->create({
            email          => BOM::Test::Customer->get_random_email_address(),
            password       => BOM::User::Password::hashpw('abc123'),
            email_verified => 1,
            account_type   => 'binary',
            residence      => 'br',
        },
        [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);

    my $client = $customer->get_client_object('CR');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $t->await::authorize({authorize => $token});

    my $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{ownership},
        {
        requests => [],
        status   => 'none',
        },
        'expected poo result for brand new client';
    cmp_deeply $res->{get_account_status}->{authentication}->{needs_verification}, [], 'expected needs verification for brand new client';

    my $poo = $client->proof_of_ownership->create({payment_service_provider => 'VISA', trace_id => 100});

    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->_clear_full_list();

    $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{ownership},
        {
        requests => [{
                id                 => re('\d+'),
                creation_time      => re('.+'),
                payment_method     => 'VISA',
                documents_required => 1,
            }
        ],
        status => 'none',
        },
        'expected result for after adding a poo request';
    cmp_deeply $res->{get_account_status}->{authentication}->{needs_verification}, ['ownership'], 'expected needs verification for pending poo';

    # start uploading
    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->_clear_full_list();

    $res = $t->await::document_upload({
            document_upload    => 1,
            document_id        => '9999',
            document_type      => 'proof_of_ownership',
            document_format    => 'png',
            expected_checksum  => '3252352323',
            file_size          => 0,
            document_format    => 'JPG',
            expected_checksum  => '12345678901234567890123456789012',
            proof_of_ownership => {
                id      => $res->{get_account_status}->{authentication}->{ownership}->{requests}->[0]->{id},
                details => {
                    payment_identifier => 'thing',
                }}});

    test_schema('document_upload', $res);

    # finish upload
    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->_clear_full_list();

    $t->await::document_upload({
            document_upload => {
                file_id => $res->{document_upload}->{file_id},
                status  => 'success'
            }});

    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->_clear_full_list();
    $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{ownership},
        {
        requests => [],
        status   => 'pending',
        },
        'expected poo result for uploaded poo';
    cmp_deeply $res->{get_account_status}->{authentication}->{needs_verification}, [qw/ownership/], 'does need verification';

    # reject

    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->reject($poo);
    $client->proof_of_ownership->_clear_full_list();
    $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{ownership},
        {
        requests => [{
                id                 => re('\d+'),
                creation_time      => re('.+'),
                payment_method     => 'VISA',
                documents_required => 1,
            }
        ],
        status => 'rejected',
        },
        'expected poo result for rejected poo';
    cmp_deeply $res->{get_account_status}->{authentication}->{needs_verification}, [qw/ownership/], 'expected needs verification for uploaded poo';

    # verify

    $t->await::authorize({authorize => $token});
    $client->proof_of_ownership->verify($poo);
    $client->proof_of_ownership->_clear_full_list();
    $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    cmp_deeply $res->{get_account_status}->{authentication}->{ownership},
        {
        requests => [],
        status   => 'verified',
        },
        'expected poo result for verified poo';
    cmp_deeply $res->{get_account_status}->{authentication}->{needs_verification}, [], 'verified poo does not need verification';

};

subtest 'Onfido status with pending flag' => sub {
    my $customer = BOM::Test::Customer->create({
            email          => BOM::Test::Customer->get_random_email_address(),
            password       => BOM::User::Password::hashpw('abc123'),
            email_verified => 1,
            account_type   => 'binary',
            residence      => 'co',
        },
        [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);

    my $client = $customer->get_client_object('CR');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $t->await::authorize({authorize => $token});

    my $pending_key = +BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $customer->get_user_id();
    my $redis       = BOM::Config::Redis::redis_events();
    $redis->set($pending_key, 1);

    my $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    is $res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{status}, 'pending', 'expected status with pending flag';

    $redis->del($pending_key);
    $res = $t->await::get_account_status({get_account_status => 1});
    test_schema('get_account_status', $res);
    is $res->{get_account_status}->{authentication}->{identity}->{services}->{onfido}->{status}, 'none', 'expected status without pending flag';
};

$t->finish_ok;

done_testing;
