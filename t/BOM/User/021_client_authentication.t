use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client top_up );
use BOM::Test::Email;
use Syntax::Keyword::Try;
use BOM::User::Client;
use BOM::User::Client::Account;

my $cr_email = 'cr@binary.com';
my $cr_user  = BOM::User->create(
    email          => $cr_email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr1->email($cr_email);
$client_cr1->set_default_account('USD');
$client_cr1->save();

my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr2->email($cr_email);
$client_cr1->set_default_account('ETH');
$client_cr1->save();

$cr_user->add_client($client_cr1);
$cr_user->add_client($client_cr2);

my $mlt_email = 'mlt@binary.com';
my $mlt_user  = BOM::User->create(
    email          => $mlt_email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});
$client_mlt->email($mlt_email);
$client_mlt->set_default_account('USD');
$client_mlt->save();
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$client_mf->email($mlt_email);
$client_mf->set_default_account('USD');
$client_mf->save();
$mlt_user->add_client($client_mlt);
$mlt_user->add_client($client_mf);

my $mx_email = 'mx@binary.com';
my $mx_user  = BOM::User->create(
    email          => $mx_email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
});
$client_mx->email($mx_email);
$client_mx->set_default_account('USD');
$client_mx->save();
my $client_mf2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$client_mf2->email($mx_email);
$client_mf2->set_default_account('USD');
$client_mf2->save();
$mx_user->add_client($client_mx);
$mx_user->add_client($client_mf2);

# Authentication should be synced between same landing companies.
subtest 'Authenticate CR' => sub {
    $client_cr1->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
    ok $client_cr1->status->allow_document_upload, "Authenticated CR is allowed to upload document";
    ok $client_cr2->status->allow_document_upload, "Authenticated CR is allowed to upload document";
    $client_cr1->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_cr1 = BOM::User::Client->new({loginid => $client_cr1->loginid});
    $client_cr2 = BOM::User::Client->new({loginid => $client_cr1->loginid});

    ok !$client_cr1->status->allow_document_upload, "Authenticated CR is not allowed to upload document";
    ok !$client_cr2->status->allow_document_upload, "Authenticated CR is not allowed to upload document";
};

# Authentication should be synced between MLT and MF.
subtest 'Authenticate MLT and MF' => sub {
    $client_mlt->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
    ok $client_mlt->status->allow_document_upload, "MLT is allowed to upload document";
    ok $client_mf->status->allow_document_upload,  "MF is allowed to upload document";
    mailbox_clear();
    $client_mlt->set_authentication('ID_DOCUMENT', {status => 'pass'});
    ok $client_mf->get_authentication('ID_DOCUMENT'),                "MF has ID_DOCUMENT";
    ok mailbox_search(subject => qr/New authenticated MF from MLT/), qq/CS get an email to check TIN and MIFIR/;
    $client_mlt = BOM::User::Client->new({loginid => $client_mlt->loginid});
    $client_mf  = BOM::User::Client->new({loginid => $client_mf->loginid});
    ok !$client_mlt->status->allow_document_upload, "Authenticated MLT is not allowed to upload document";
    ok !$client_mf->status->allow_document_upload,  "Authenticated MF is not allowed to upload document.";

    $client_mlt->set_authentication('ID_NOTARIZED', {status => 'pass'});
    ok $client_mf->get_authentication('ID_NOTARIZED'), "MF has ID_NOTARIZED";
    my $client_mf2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $client_mf2->email($mlt_email);
    $client_mf2->set_default_account('USD');
    $client_mf2->save();
    $mlt_user->add_client($client_mf2);
    mailbox_clear();
    $client_mf2->sync_authentication_from_siblings;
    ok $client_mf2->get_authentication('ID_NOTARIZED'),              "Authenticated MF based on MLT has ID_NOTARIZED";
    ok mailbox_search(subject => qr/New authenticated MF from MLT/), qq/CS get an email to check TIN and MIFIR/;
};

subtest 'set_authentication_and_status' => sub {
    my $cr_user = BOM::User->create(
        email          => 'test@deriv.com',
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr1->email('test@deriv.com');
    $client_cr1->set_default_account('USD');
    $client_cr1->save();

    $client_cr1->set_authentication_and_status('NEEDS_ACTION', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_DOCUMENT'), "Client has NEEDS_ACTION";
    ok $client_cr1->status->allow_document_upload,     "Client is allowed to upload document";
    ok !$client_cr1->status->address_verified,         "Client is not address verified";
    is $client_cr1->get_authentication('ID_DOCUMENT')->{status}, 'needs_action', 'Expected status';
    ok $client_cr1->status->allow_document_upload, "Client is allowed to upload document";
    ok !$client_cr1->fully_authenticated(),        'Client is not fully authenticated';
    is $client_cr1->authentication_status(), 'needs_action', 'expected auth status';

    $client_cr1->set_authentication_and_status('ID_DOCUMENT', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_DOCUMENT'), "Client has ID_DOCUMENT";
    ok !$client_cr1->status->allow_document_upload,    "Authenticated client is not allowed to upload document";
    ok $client_cr1->status->address_verified,          "Client is address verified";

    $client_cr1->set_authentication_and_status('ID_DOCUMENT', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_DOCUMENT'), "Client has ID_DOCUMENT";
    ok !$client_cr1->status->allow_document_upload,    "Authenticated client is not allowed to upload document";
    ok $client_cr1->fully_authenticated(),             'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'scans', 'expected auth status';

    $client_cr1->status->clear_address_verified();
    $client_cr1->status->_build_all;
    $client_cr1->set_authentication_and_status('ID_NOTARIZED', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_NOTARIZED'), "Client has ID_NOTARIZED";
    ok $client_cr1->fully_authenticated(),              'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'notarized', 'expected auth status';
    ok $client_cr1->status->address_verified, "Client is address verified";

    $client_cr1->status->clear_address_verified();
    $client_cr1->status->_build_all;
    $client_cr1->set_authentication_and_status('ID_ONLINE', 'Sarah Aziziyan');
    ok !$client_mf2->get_authentication('ID_ONLINE'), "Client has not ID_ONLINE";
    ok $client_cr1->fully_authenticated(),            'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'online', 'expected auth status';
    ok $client_cr1->status->address_verified, "Client is address verified";
    is $client_cr1->get_idv_status(), 'none', 'ID_ONLINE authentication does not affect idv status';

    $client_cr1->status->clear_address_verified();
    $client_cr1->status->_build_all;
    $client_cr1->set_authentication_and_status('NEEDS_ACTION', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_DOCUMENT'), "Client has NEEDS_ACTION";
    ok $client_cr1->status->allow_document_upload,     "Client is allowed to upload document";
    ok !$client_cr1->status->address_verified,         "Client is not address verified";
    is $client_cr1->get_idv_status(), 'none', 'NEEDS_ACTION authentication does not affect idv status';

    $client_cr1->status->clear_address_verified();
    $client_cr1->status->_build_all;
    $client_cr1->set_authentication_and_status('IDV', 'Testing');
    is $client_cr1->get_authentication('IDV')->{status}, 'pass', 'Expected status';
    ok !$client_mf2->get_authentication('IDV'), "Client has not IDV";
    ok $client_cr1->status->address_verified,   "Client is address verified";
    is $client_cr1->get_idv_status(), 'verified', 'IDV authentication returns idv status verified';

    ok $client_cr1->fully_authenticated(), 'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'idv', 'expected auth status';

    $client_cr1->set_authentication_and_status('IDV_PHOTO', 'Testing');
    is $client_cr1->get_authentication('IDV_PHOTO')->{status}, 'pass', 'Expected status';
    ok !$client_mf2->get_authentication('IDV_PHOTO'), "Client has not IDV_PHOTO";
    ok $client_cr1->fully_authenticated(),            'Client is not fully authenticated';
    is $client_cr1->authentication_status(), 'idv_photo', 'expected auth status';
    is $client_cr1->get_idv_status(),        'verified',  'IDV_PHOTO authentication returns idv status verified';

    subtest 'IDV + Photo' => sub {
        my $tests = [{
                idv_photoid_lc      => 1,
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                high_risk           => 0,
                fully_authenticated => 1,
            },
            {
                idv_photoid_lc      => 1,
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                high_risk           => 0,
                ignore_idv          => 1,
                fully_authenticated => 0,
            },
            {
                idv_photoid_lc      => 0,
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                high_risk           => 0,
                fully_authenticated => 0,
            },
            {
                idv_photoid_lc      => 1,
                authentication      => 'DUBIOUS_METHOD',
                status              => 'pass',
                high_risk           => 0,
                fully_authenticated => 0,
            },
            {
                idv_photoid_lc      => 1,
                authentication      => 'IDV_PHOTO',
                status              => 'pending',
                high_risk           => 0,
                fully_authenticated => 0,
            },
            {
                idv_photoid_lc      => 1,
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                high_risk           => 1,
                fully_authenticated => 0,
            },
        ];
        for my $test ($tests->@*) {
            my ($idv_photoid_lc, $authentication, $status, $high_risk, $ignore_idv, $fully_authenticated) =
                @{$test}{qw/idv_photoid_lc authentication status high_risk ignore_idv fully_authenticated/};

            $_->delete for @{$client_cr1->client_authentication_method};
            $client_cr1->set_authentication($authentication, {status => $status}, 'testing script');

            my $client_mock = Test::MockModule->new('BOM::User::Client');
            $client_mock->mock(
                'is_high_risk',
                sub {
                    return $high_risk;
                });

            my $lc_mock = Test::MockModule->new('LandingCompany');
            $lc_mock->mock(
                'fully_authenticated_with_idv_photoid',
                sub {
                    return $idv_photoid_lc;
                });

            $client_cr1 = BOM::User::Client->new({loginid => $client_cr1->loginid});
            # we need xand (xnor amirite?) so we will use these auxiliar vars to store the booleans
            my $x = $client_cr1->fully_authenticated({ignore_idv => $ignore_idv}) ? 1 : 0;
            my $y = $fully_authenticated                                          ? 1 : 0;

            is $x,                                   $y,     'Expected fully auth result';
            is $client_cr1->get_manual_poi_status(), 'none', 'manual POI status should remain none regardless';

            $client_mock->unmock_all;
            $lc_mock->unmock_all;

        }
    };

    subtest 'IDV' => sub {
        my $tests = [{
                authentication      => 'IDV',
                status              => 'pass',
                fully_authenticated => 1,
                auth_with_idv       => 1,
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                ignore_idv          => 1,
                fully_authenticated => 0,
                auth_with_idv       => 1,
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                fully_authenticated => 1,
                auth_with_idv       => 1,
            },
            {
                authentication      => 'DUBIOUS_METHOD',
                status              => 'pass',
                fully_authenticated => 0,
                auth_with_idv       => 0,
            },
            {
                authentication      => 'IDV',
                status              => 'pending',
                fully_authenticated => 0,
                auth_with_idv       => 0,
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                fully_authenticated => 0,
                aml_risk            => 'high',
                auth_with_idv       => 0,
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                fully_authenticated => 0,
                sr_risk             => 'high',
                auth_with_idv       => 0,
            },
        ];

        for my $test ($tests->@*) {
            my $client_mock = Test::MockModule->new(ref($client_cr1));
            $client_mock->mock(
                'risk_level_sr',
                sub {
                    return $test->{sr_risk} // 'low';
                });
            $client_mock->mock(
                'risk_level_aml',
                sub {
                    return $test->{aml_risk} // 'low';
                });

            my ($authentication, $status, $ignore_idv, $fully_authenticated, $auth_with_idv) =
                @{$test}{qw/authentication status ignore_idv fully_authenticated auth_with_idv/};

            $_->delete for @{$client_cr1->client_authentication_method};
            $client_cr1->set_authentication($authentication, {status => $status}, 'testing script');

            $client_cr1 = BOM::User::Client->new({loginid => $client_cr1->loginid});
            my $x = $client_cr1->fully_authenticated({ignore_idv => $ignore_idv}) ? 1 : 0;
            my $y = $fully_authenticated                                          ? 1 : 0;

            is $x, $y, 'Expected fully auth result';

            is $client_cr1->poa_authenticated_with_idv, $auth_with_idv, 'Expected poa authenticated with IDV';

            is $client_cr1->get_manual_poi_status(), 'none', 'manual POI status should remain none regardless';
        }
    };
};

subtest 'set_staff_name' => sub {

    my $client = create_client();
    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'}, 'Sarah Aziziyan');
    my %client_status = map { $_ => $client->status->$_ } @{$client->status->all};
    is($client_status{"allow_document_upload"}->{"staff_name"}, 'Sarah Aziziyan', "staff_name is correct");
};

done_testing();
