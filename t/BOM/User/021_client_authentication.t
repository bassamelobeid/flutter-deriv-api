use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up );
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
    ok $client_mf->get_authentication('ID_DOCUMENT'), "MF has ID_DOCUMENT";
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
    ok $client_mf2->get_authentication('ID_NOTARIZED'), "Authenticated MF based on MLT has ID_NOTARIZED";
    ok mailbox_search(subject => qr/New authenticated MF from MLT/), qq/CS get an email to check TIN and MIFIR/;
};

# We should not sync authentication from MX to MF if it was from Experian
# We should sync authentication from MF to MX
subtest 'Authenticate MX and MF' => sub {
    $client_mx->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
    ok $client_mx->status->allow_document_upload, "MX client is allowed to upload document";
    $client_mx->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_mx  = BOM::User::Client->new({loginid => $client_mx->loginid});
    $client_mf2 = BOM::User::Client->new({loginid => $client_mf2->loginid});
    ok !$client_mx->status->allow_document_upload, "Authenticated client is not allowed to upload document";
    ok $client_mf2->get_authentication('ID_DOCUMENT'), "MF has ID_DOCUMENT";
    $client_mf2->set_authentication('ID_NOTARIZED', {status => 'pass'});
    ok $client_mx->get_authentication('ID_NOTARIZED'), "MX has ID_NOTARIZED";
    $client_mx->set_authentication('ID_ONLINE', {status => 'pass'});
    ok !$client_mf2->get_authentication('ID_ONLINE'), "MF has not ID_ONLINE";

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
    ok $client_cr1->status->allow_document_upload, "Client is allowed to upload document";

    $client_cr1->set_authentication_and_status('ID_DOCUMENT', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_DOCUMENT'), "Client has ID_DOCUMENT";
    ok !$client_cr1->status->allow_document_upload, "Authenticated client is not allowed to upload document";

    $client_cr1->set_authentication_and_status('ID_NOTARIZED', 'Sarah Aziziyan');
    ok $client_cr1->get_authentication('ID_NOTARIZED'), "Client has ID_NOTARIZED";

    $client_cr1->set_authentication_and_status('ID_ONLINE', 'Sarah Aziziyan');
    ok !$client_mf2->get_authentication('ID_ONLINE'), "Client has not ID_ONLINE";

};

done_testing();
