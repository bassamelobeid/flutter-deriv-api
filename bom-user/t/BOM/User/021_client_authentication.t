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

my $email = 'mf@binary.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$client_mf->email($email);
$client_mf->set_default_account('USD');
$client_mf->save();

$user->add_client($client_mf);
my $client_mf1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$client_mf1->email($email);
$client_mf1->set_default_account('USD');
$client_mf1->save();

$user->add_client($client_mf1);

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

subtest 'Authenticate MF' => sub {
    $client_mf->set_authentication('ID_DOCUMENT', {status => 'needs_action'});

    ok $client_mf->status->allow_document_upload, "MF is allowed to upload document";
    mailbox_clear();
    $client_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
    ok $client_mf->get_authentication('ID_DOCUMENT'), "MF has ID_DOCUMENT";

    $client_mf = BOM::User::Client->new({loginid => $client_mf->loginid});

    ok !$client_mf->status->allow_document_upload, "Authenticated MF is not allowed to upload document.";

    $client_mf->set_authentication('ID_NOTARIZED', {status => 'pass'});
    ok $client_mf->get_authentication('ID_NOTARIZED'), "MF has ID_NOTARIZED";
};

subtest 'ID_PO_BOX authenticated only for SVG' => sub {
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    ok $client_cr1->landing_company->short eq 'svg', 'Client is SVG';

    $client_cr1->set_authentication('ID_PO_BOX', {status => 'pass'});
    ok $client_cr1->get_authentication('ID_PO_BOX'), "SVG Client has ID_PO_BOX";
    ok $client_cr1->fully_authenticated(),           'SVG Client is fully authenticated';

    my $client_mf1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    ok $client_mf1->landing_company->short ne 'svg', 'Client is not SVG';
    $client_cr1->set_authentication('ID_PO_BOX', {status => 'pass'});
    ok $client_cr1->get_authentication('ID_PO_BOX'), "Non SVG Client has ID_PO_BOX";
    ok $client_cr1->fully_authenticated(),           'Non SVG Client is not fully authenticated';

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
    $client_cr1->set_authentication_and_status('ID_PO_BOX', 'Test');
    ok !$client_mf1->get_authentication('ID_PO_BOX'), "Client has not ID_PO_BOX";
    ok $client_cr1->fully_authenticated(),            'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'po_box', 'expected auth status';
    ok $client_cr1->status->address_verified, "Client is address verified";
    is $client_cr1->get_idv_status(), 'none', 'ID_PO_BOX authentication does not affect idv status';

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
    ok !$client_mf1->get_authentication('ID_ONLINE'), "Client has not ID_ONLINE";
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
    ok !$client_mf1->get_authentication('IDV'), "Client has not IDV";
    ok $client_cr1->status->address_verified,   "Client is address verified";
    is $client_cr1->get_idv_status(), 'verified', 'IDV authentication returns idv status verified';

    ok $client_cr1->fully_authenticated(), 'Client is fully authenticated';
    is $client_cr1->authentication_status(), 'idv', 'expected auth status';

    $client_cr1->set_authentication_and_status('IDV_PHOTO', 'Testing');
    is $client_cr1->get_authentication('IDV_PHOTO')->{status}, 'pass', 'Expected status';
    ok !$client_mf1->get_authentication('IDV_PHOTO'), "Client has not IDV_PHOTO";
    ok $client_cr1->fully_authenticated(),            'Client is not fully authenticated';
    is $client_cr1->authentication_status(), 'idv_photo', 'expected auth status';
    is $client_cr1->get_idv_status(),        'verified',  'IDV_PHOTO authentication returns idv status verified';

    subtest 'IDV Fully Auth' => sub {
        my $tests = [{
                authentication      => 'IDV_ADDRESS',
                status              => 'pass',
                aml_risk            => 'high',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv address high risk',
            },
            {
                authentication      => 'IDV_ADDRESS',
                status              => 'pass',
                aml_risk            => 'low',
                ignore_idv          => 1,
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv address ignore idv',
            },
            {
                authentication      => 'IDV_ADDRESS',
                status              => 'pending',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv address pending status',
            },
            {
                authentication      => 'IDV_ADDRESS',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv address unsupported lc'
            },
            {
                authentication      => 'IDV_ADDRESS',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'bvi',
                auth_with_idv       => 1,
                fully_authenticated => 1,
                case                => 'idv address pass'
            },
            {
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                aml_risk            => 'high',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv photo high risk',
            },
            {
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                aml_risk            => 'low',
                ignore_idv          => 1,
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv photo ignore idv',
            },
            {
                authentication      => 'IDV_PHOTO',
                status              => 'pending',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv photo pending status',
            },
            {
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv photo unsupported lc'
            },
            {
                authentication      => 'IDV_PHOTO',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'bvi',
                auth_with_idv       => 1,
                fully_authenticated => 1,
                case                => 'idv photo pass'
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                aml_risk            => 'high',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv high risk',
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                aml_risk            => 'low',
                ignore_idv          => 1,
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv poa ignore idv',
            },
            {
                authentication      => 'IDV',
                status              => 'pending',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv poa pending status',
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'maltainvest',
                auth_with_idv       => 0,
                fully_authenticated => 0,
                case                => 'idv poa unsupported lc'
            },
            {
                authentication      => 'IDV',
                status              => 'pass',
                aml_risk            => 'low',
                lc                  => 'labuan',
                auth_with_idv       => 1,
                fully_authenticated => 1,
                case                => 'idv poa pass'
            }];
        for my $test ($tests->@*) {
            my ($authentication, $status, $aml_risk, $ignore_idv, $lc, $auth_with_idv, $fully_authenticated, $case) =
                @{$test}{qw/authentication status aml_risk ignore_idv lc auth_with_idv fully_authenticated case/};

            $client_cr1->set_authentication($authentication, {status => $status}, 'testing script');

            my $client_mock = Test::MockModule->new('BOM::User::Client');
            $client_mock->mock(
                'risk_level_aml',
                sub {
                    return $aml_risk;
                });

            $client_cr1 = BOM::User::Client->new({loginid => $client_cr1->loginid});

            # we need xand (xnor amirite?) so we will use these auxiliar vars to store the booleans
            my $x = $client_cr1->fully_authenticated({ignore_idv => $ignore_idv, landing_company => $lc}) ? 1 : 0;
            my $y = $fully_authenticated                                                                  ? 1 : 0;

            is $x,                                                                $y,             "Expected fully auth result for: $case";
            is $client_cr1->poa_authenticated_with_idv({landing_company => $lc}), $auth_with_idv, 'Expected poa authenticated with IDV result';
            is $client_cr1->get_manual_poi_status(),                              'none',         'manual POI status should remain none regardless';

            $client_mock->unmock_all;

        }
    };

};

subtest 'set_staff_name' => sub {

    my $client = create_client();
    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'}, 'Sarah Aziziyan');
    my %client_status = map { $_ => $client->status->$_ } @{$client->status->all};
    is($client_status{"allow_document_upload"}->{"staff_name"}, 'Sarah Aziziyan', "staff_name is correct");
};

subtest 'fully_authenticated with ID_PO_BOX enabled landing company' => sub {
    my $client = create_client();
    my $mock   = Test::MockModule->new('BOM::User::Client');

    $mock->mock(
        'landing_company',
        sub {
            my $return_value = $mock->original('landing_company')->(@_);
            $return_value->{id_po_box_enabled} = 0;
            return $return_value;
        });

    $client->set_authentication('ID_PO_BOX', {status => 'pass'}, 'test');

    ok !$client->fully_authenticated(), 'Client is notfully authenticated if id_po_box is not enabled for the landing company';

    $mock->mock(
        'landing_company',
        sub {
            my $return_value = $mock->original('landing_company')->(@_);
            $return_value->{id_po_box_enabled} = 1;
            return $return_value;
        });

    ok $client->fully_authenticated(), 'Client is fully authenticated if id_po_box has been set and enabled for the landing company';
    $mock->unmock_all;
};

done_testing();
