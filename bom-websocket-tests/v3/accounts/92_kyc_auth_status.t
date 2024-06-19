use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use BOM::Config::Redis;
use await;

my $t = build_wsapi_test();

subtest 'new client with no attempts' => sub {
    my ($vr_client, $user) = create_vr_account({
        email           => 'no_poi_attempts@deriv.com',
        client_password => 'secret_pwd',
    });

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });

    $user->add_client($client_cr);

    my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
    $t->await::authorize({authorize => $token_cr});

    my $expected_response_object = {
        identity => {
            last_rejected      => {},
            available_services => ['idv', 'onfido', 'manual'],
            service            => 'none',
            status             => 'none',
        },
        address => {
            status              => 'none',
            supported_documents => ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
        },
    };

    my $res = $t->await::kyc_auth_status({kyc_auth_status => 1});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object, 'Expected response object';
};

subtest 'IDV attempts' => sub {
    my $user = BOM::User->create(
        email    => 'idv_attempts@deriv.com',
        password => 'secret_pwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);
    $client_cr->binary_user_id($user->id);
    $client_cr->save;

    my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
    $t->await::authorize({authorize => $token_cr});

    my $idv = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

    my $doc_id_1;
    my $document;
    lives_ok {
        $document = $idv->add_document({
            issuing_country => 'zw',
            number          => '00005000A00',
            type            => 'national_id',
        });
        $doc_id_1 = $document->{id};
        $idv->update_document_check({
            document_id => $doc_id_1,
            status      => 'failed',
            messages    => ["UNEXPECTED_ERROR"],
            provider    => 'smile_identity'
        });
    }
    'first client document added and updated successfully';

    my $expected_response_object = {
        identity => {
            last_rejected => {
                rejected_reasons => ['UnexpectedError'],
                document_type    => 'national_id',
                report_available => 1
            },
            available_services => ['idv', 'onfido', 'manual'],
            service            => 'idv',
            status             => 'rejected',
        },
        address => {
            status              => 'none',
            supported_documents => ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
        },
    };

    my $expected_response_object_country = {
        identity => {
            last_rejected => {
                rejected_reasons => ['UnexpectedError'],
                document_type    => 'national_id',
                report_available => 1
            },
            available_services  => ['idv', 'onfido', 'manual'],
            service             => 'idv',
            status              => 'rejected',
            supported_documents => {
                idv => {
                    national_id => {
                        display_name => 'National ID Number',
                        format       => '^[0-9]{8,9}[a-zA-Z]{1}[0-9]{2}$'
                    }
                },
                onfido => {
                    national_identity_card => {display_name => 'National Identity Card'},
                    passport               => {display_name => 'Passport'}}}
        },
        address => {
            status              => 'none',
            supported_documents => ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
        },
    };

    my $res = $t->await::kyc_auth_status({kyc_auth_status => 1});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object, 'Expected response object';

    $res = $t->await::kyc_auth_status({kyc_auth_status => 1, country => "zw"});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object_country, 'Expected response object';

    my $doc_id_2;
    lives_ok {
        $document = $idv->add_document({
            issuing_country => 'zw',
            number          => '12300000A00',
            type            => 'national_id',
        });
        $doc_id_2 = $document->{id};
        $idv->update_document_check({
            document_id => $doc_id_2,
            status      => 'verified',
            messages    => [],
            provider    => 'smile_identity'
        });
    }
    'second client document added and updated successfully';

    $client_cr->status->setnx('age_verification', 'system', 'test');
    ok $client_cr->status->age_verification, 'client is age verified';

    $expected_response_object = {
        identity => {
            last_rejected      => {},
            available_services => ['manual'],
            service            => 'idv',
            status             => 'verified',
        },
        address => {
            status              => 'none',
            supported_documents => ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
        },
    };

    $res = $t->await::kyc_auth_status({kyc_auth_status => 1});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object, 'Expected response object';

    $res = $t->await::kyc_auth_status({kyc_auth_status => 1, country => "zw"});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object, 'Expected response object';
};

subtest 'Landing Companies provided as arguments' => sub {
    my $user = BOM::User->create(
        email    => 'idv_lcs@deriv.com',
        password => 'secret_pwd'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id
    });

    $user->add_client($client_cr);

    my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
    $t->await::authorize({authorize => $token_cr});

    my $idv = BOM::User::IdentityVerification->new(user_id => $client_cr->binary_user_id);

    my $doc_id_1;
    my $document;
    lives_ok {
        $document = $idv->add_document({
            issuing_country => 'qq',
            number          => '123456789',
            type            => 'passport',
        });
        $doc_id_1 = $document->{id};
        $idv->update_document_check({
            document_id => $doc_id_1,
            status      => 'refuted',
            messages    => ["NAME_MISMATCH"],
            provider    => 'qa'
        });
    }
    'first client document added and updated successfully';

    my $expected_response_object = {
        svg => {
            identity => {
                last_rejected => {
                    rejected_reasons => ['NameMismatch'],
                    document_type    => 'passport',
                    report_available => 1
                },
                available_services => ['idv', 'onfido', 'manual'],
                service            => 'idv',
                status             => 'rejected',
            },
            address => {
                status              => 'none',
                supported_documents =>
                    ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
            }
        },
        malta => {
            identity => {
                last_rejected      => {},
                available_services => ['onfido', 'manual'],
                service            => 'none',
                status             => 'none',
            },
            address => {
                status              => 'none',
                supported_documents =>
                    ['utility_bill', 'phone_bill', 'bank_statement', 'affidavit', 'official_letter', 'rental_agreement', 'poa_others'],
            }}};

    my $res = $t->await::kyc_auth_status({kyc_auth_status => 1, landing_companies => ['svg', 'malta']});
    test_schema('kyc_auth_status', $res);
    cmp_deeply $res->{kyc_auth_status}, $expected_response_object, 'Expected response object';
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                account_type    => 'binary',
                email_verified  => 1,
                residence       => 'id'
            },
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
