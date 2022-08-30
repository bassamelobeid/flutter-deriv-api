use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::BOM::RPC::QueueClient;

use Date::Utility;

use BOM::RPC::v3::Accounts;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Utility;
use BOM::User;
use BOM::Platform::Token;

my $c = Test::BOM::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;
my $documents_uploaded;
my $edd_status;
my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');

my $user_mock = Test::MockModule->new('BOM::User');

$documents_mock->mock(
    'uploaded',
    sub {
        my ($self) = @_;

        $self->_clear_uploaded;

        return $documents_uploaded if defined $documents_uploaded;
        return $documents_mock->original('uploaded')->(@_);
    });
$user_mock->mock(
    'get_edd_status',
    sub {
        my ($self) = @_;
        return $edd_status if defined $edd_status;
        return $user_mock->original('get_edd_status')->(@_);
    });
subtest 'idv details' => sub {
    my %rejected_reasons = BOM::Platform::Utility::rejected_identity_verification_reasons()->%*;
    my $client           = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    $client->email('idv+details@binary.com');
    $client->save;

    my $user = BOM::User->create(
        email    => 'idv+details@binary.com',
        password => 'Cookie'
    );
    $user->add_client($client);

    my $non_expired_date = Date::Utility->today->_plus_years(1);
    my $expired_date     = Date::Utility->today->_minus_years(1);

    my $tests = [{
            title    => 'documentless scenario',
            document => undef,
            check    => undef,
            result   => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'none',
                reported_properties => {},
            }
        },
        {
            title    => 'verified - no expiration date',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => undef,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'verified',
                reported_properties => {},
            }
        },
        {
            title    => 'verified - non expired expiration date',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => $non_expired_date->date_yyyymmdd,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'verified',
                expiry_date         => $non_expired_date->epoch,
                reported_properties => {},
            }
        },
        {
            title    => 'verified but expired',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => $expired_date->date_yyyymmdd,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'expired',
                expiry_date         => $expired_date->epoch,
                reported_properties => {},
            }
        },
        {
            title    => 'refuted',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'refuted',
                status_messages => '["UNDERAGE", "NAME_MISMATCH"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [map { $rejected_reasons{$_} } qw/UNDERAGE NAME_MISMATCH/],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'failed',
                status_messages => '["UNDERAGE", "TEST"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [map { $rejected_reasons{$_} } qw/UNDERAGE/],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'pending',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'pending',
                status_messages => '["UNDERAGE", "TEST"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'pending',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000001',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '["EMPTY_STATUS"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => ["The verification status was empty, rejected for lack of information."],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000002',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '["INFORMATION_LACK"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => ["The verfication is passed but the personal info is not available to compare."],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000000',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '["DOCUMENT_REJECTED"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => ["Document was rejected by the provider."],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000003',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '["UNAVAILABLE_ISSUER"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => ["The verification status is not available, provider says: Issuer Unavailable."],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000004',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '["UNAVAILABLE_STATUS"]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => ["The verification status is not available, provider says: N/A."],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'empty sting in status messages',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000004',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'empty json array in status messages',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000004',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '[]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'undef elem in status messages',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000004',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => '[null]',
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'undef in status messages',
            document => {
                issuing_country => 'ng',
                document_number => '0000000000004',
                document_type   => 'voter_id',
                status          => 'failed',
                status_messages => undef,
            },
            result => {
                submissions_left    => 3,
                last_rejected       => [],
                status              => 'rejected',
                reported_properties => {},
            }
        },
    ];

    my $document;

    my $doc_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $doc_mock->mock(
        'get_last_updated_document',
        sub {
            return $document;
        });

    for my $test ($tests->@*) {
        my ($title, $doc_data, $check_data, $result, $rp) = @{$test}{qw/title document check result/};

        if ($doc_data) {
            $document = {
                user_id => $client->user->id,
                $doc_data->%*,
            };

        } else {
            $document = undef;
        }

        cmp_deeply BOM::RPC::v3::Accounts::_get_idv_service_detail($client), $result, "Expected result: $title";
    }

    $doc_mock->unmock_all;
};

subtest 'Proof of Ownership' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+poo@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'none',
        requests => [],
        },
        'Expected POO from auth';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate';

    my $poo = $client->proof_of_ownership->create({
        payment_method            => 'VISA',
        payment_method_identifier => '99999'
    });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'none',
        requests => [{
                payment_method            => 'VISA',
                payment_method_identifier => '99999',
                id                        => re('\d+'),
                creation_time             => re('.+'),
            }
        ],
        },
        'Expected POO result when pending POO';

    cmp_bag $result->{authentication}->{needs_verification}, [qw/ownership/], 'POO needed';

    my $file_id = upload(
        $client,
        {
            document_id => 111,
            checksum    => 'checkitup'
        });

    ok $file_id, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'EL CARPINCHO',
                expdate => '12/28'
            },
            client_authentication_document_id => $file_id,
        });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'pending',
        requests => [],
        },
        'Expected POO after fulfilling';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate';

    $client->proof_of_ownership->reject($poo);
    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'rejected',
        requests => [{
                payment_method            => 'VISA',
                payment_method_identifier => '99999',
                id                        => re('\d+'),
                creation_time             => re('.+'),
            }
        ],
        },
        'Expected POO after rejecting';

    cmp_bag $result->{authentication}->{needs_verification}, [qw/ownership/], 'Needs verification';

    $file_id = upload(
        $client,
        {
            document_id => 222,
            checksum    => 'heyyou'
        });

    ok $file_id, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'EL CARPINCHO',
                expdate => '12/28'
            },
            client_authentication_document_id => $file_id,
        });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'pending',
        requests => [],
        },
        'Expected POO after fulfilling again';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate (pending)';

    $client->proof_of_ownership->verify($poo);
    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'verified',
        requests => [],
        },
        'Expected POO after verifying';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Does not need verification';

    # after some time new poo is requested
    $poo = $client->proof_of_ownership->create({
        payment_method            => 'VISA',
        payment_method_identifier => '12345'
    });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'none',
        requests => [{
                payment_method            => 'VISA',
                payment_method_identifier => '12345',
                id                        => re('\d+'),
                creation_time             => re('.+'),
            }
        ],
        },
        'Expected POO result when pending POO';

    cmp_bag $result->{authentication}->{needs_verification}, [qw/ownership/], 'POO needed';

    $file_id = upload(
        $client,
        {
            document_id => 333,
            checksum    => 'donotrepeat'
        });

    ok $file_id, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'LA CAPYBARA',
                expdate => '12/12'
            },
            client_authentication_document_id => $file_id,
        });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'pending',
        requests => [],
        },
        'Expected POO after fulfilling again';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate (pending)';

    $client->proof_of_ownership->reject($poo);
    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'rejected',
        requests => [{
                payment_method            => 'VISA',
                payment_method_identifier => '12345',
                id                        => re('\d+'),
                creation_time             => re('.+'),
            }
        ],
        },
        'Expected POO after rejecting';

    cmp_bag $result->{authentication}->{needs_verification}, [qw/ownership/], 'Needs verification';

    $file_id = upload(
        $client,
        {
            document_id => 444,
            checksum    => 'anotherone'
        });

    ok $file_id, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'LA CAPYBARA',
                expdate => '12/13'
            },
            client_authentication_document_id => $file_id,
        });

    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'pending',
        requests => [],
        },
        'Expected POO after fulfilling again';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate (pending)';

    $client->proof_of_ownership->verify($poo);
    $client->proof_of_ownership->_clear_full_list();
    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{ownership},
        {
        status   => 'verified',
        requests => [],
        },
        'Expected POO after verifying';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Does not need verification';
};

subtest 'Proof of Income' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'test+po_income@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    BOM::Config::Runtime->instance->app_config->compliance->enhanced_due_diligence->auto_lock(1);
    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'none'}, 'Expected proof of income from auth';

    cmp_bag $result->{authentication}->{needs_verification}, [], 'Nothing to authenticate';
    $edd_status         = {status => 'pending'};
    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "uploaded",
                    type        => "brokerage_statement",
                    },
            },
            is_pending => 1,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'pending'}, 'Expected proof of income from auth';

    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of fund sdocuments need to be provided';

    $edd_status = {status => 'in_progress'};

    cmp_deeply $result->{authentication}->{income}, {status => 'pending'}, 'Expected proof of income from auth';

    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of income documents need to be provided';

    $edd_status = {status => 'rejected'};

    cmp_deeply $result->{authentication}->{income}, {status => 'pending'}, 'Expected POF from auth';

    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of funds documents need to be provided';

    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "verified",
                    type        => "brokerage_statement",
                    },
            },
            is_verified => 1,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'verified'}, 'Expected proof of income from auth';
    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'income documents need to be provided';

    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "rejected",
                    type        => "brokerage_statement",
                    },
            },
            is_rejected => 1,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'rejected'}, 'Expected proof of income from auth';
    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of funds documents need to be provided';

    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "pending",
                    type        => "brokerage_statement",
                    },
            },
            is_pending  => 1,
            is_rejected => 2,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply $result->{authentication}->{income}, {status => 'pending'}, 'Expected proof of income to be pending';
    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of funds documents need to be provided';

    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "rejected",
                    type        => "brokerage_statement",
                    },
            },
            is_pending  => 1,
            is_rejected => 3,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'pending'}, 'Expected proof of income to be pending';
    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of funds documents need to be provided';

    $documents_uploaded = {
        proof_of_income => {
            documents => {
                $client->loginid
                    . '_brokerage_statement.1319_back' => {
                    expiry_date => undef,
                    format      => "png",
                    id          => 123,
                    status      => "rejected",
                    type        => "brokerage_statement",
                    },
            },
            is_rejected => 3,
        },
    };

    $result = $c->tcall('get_account_status', {token => $token});

    cmp_deeply $result->{authentication}->{income}, {status => 'locked'}, 'Expected proof of income to be pending';
    cmp_bag $result->{authentication}->{needs_verification}, ['income'], 'proof of funds documents need to be provided';
};
subtest 'backtest for Onfido disabled country' => sub {
    my $test_client_disabled_country = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'ir',
    });
    $test_client_disabled_country->email('testing.onfido+disabled+country@binary.com');
    $test_client_disabled_country->set_default_account('USD');
    $test_client_disabled_country->save;

    my $user_disabled_country = BOM::User->create(
        email    => 'testing.onfido+disabled+country@binary.com',
        password => 'hey you'
    );

    $user_disabled_country->add_client($test_client_disabled_country);

    my $token_disabled_country = $m->create_token($test_client_disabled_country->loginid, 'test token');

    my $config_mock = Test::MockModule->new('BOM::Config::Onfido');
    my $country_supported;
    $config_mock->mock(
        'is_country_supported',
        sub {
            return $country_supported;
        });

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $onfido_document_sub_result;
    my $onfido_check_result;

    $onfido_mock->mock(
        'get_latest_check',
        sub {
            return {
                report_document_status     => 'complete',
                report_document_sub_result => $onfido_document_sub_result,
                user_check                 => {
                    result => $onfido_check_result,
                },
            };
        });

    my $tests = [{
            check_result      => 'consider',
            docum_result      => 'rejected',
            country_supported => 1,
            expected          => {
                status => 'rejected',
            },
            name => 'rejected status, supported country',
        },
        {
            check_result      => 'consider',
            docum_result      => 'suspected',
            country_supported => 1,
            expected          => {
                status => 'suspected',
            },
            name => 'suspected status, supported country',
        },
        {
            check_result      => 'clear',
            docum_result      => undef,
            country_supported => 1,
            expected          => {
                status => 'verified',
            },
            name => 'verified status, supported country',
        },
        {
            check_result      => 'consider',
            docum_result      => 'rejected',
            country_supported => 0,
            expected          => {
                status => 'rejected',
            },
            name => 'rejected status, unsupported country',
        },
        {
            check_result      => 'consider',
            docum_result      => 'suspected',
            country_supported => 0,
            expected          => {
                status => 'suspected',
            },
            name => 'suspected status, unsupported country',
        },
        {
            check_result      => 'clear',
            docum_result      => undef,
            country_supported => 0,
            expected          => {
                status => 'verified',
            },
            name => 'verified status, unsupported country',
        },
        {
            docum_result      => 'awaiting_applicant',
            country_supported => 0,
            expected          => {
                status => 'none',
            },
            name => 'when it would have been pending, map it into `none` for unsupported country',
        }];

    for my $test ($tests->@*) {
        ($onfido_document_sub_result, $onfido_check_result, $country_supported) = @$test{qw/docum_result check_result country_supported/};

        subtest $test->{name} => sub {
            my $result = $c->tcall('get_account_status', {token => $token_disabled_country});

            cmp_deeply $result->{authentication}->{identity}->{services}->{onfido},
                +{
                submissions_left     => 3,
                last_rejected        => [],
                country_code         => 'IRN',
                reported_properties  => {},
                status               => 'none',
                documents_supported  => ['Passport'],
                is_country_supported => $country_supported,
                $test->{expected}->%*,
                },
                'Expected onfido result';
        };
    }

    $onfido_mock->unmock_all;
};

sub upload {
    my ($client, $doc) = @_;

    my $file = $client->start_document_upload({
        document_type   => 'proof_of_ownership',
        document_format => 'png',
        checksum        => 'checkthis',
        document_id     => 555,
        $doc ? $doc->%* : (),
    });

    return $client->finish_document_upload($file->{file_id});
}
$documents_mock->unmock_all;
$user_mock->unmock_all;
done_testing();
