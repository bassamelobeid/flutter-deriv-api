use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test::Helper::FinancialAssessment;

use BOM::User::Client;
use BOM::User::Password;
use BOM::User::FinancialAssessment qw(update_financial_assessment);

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');

my $user = BOM::User->create(
    email          => $email,
    password       => $hash_pwd,
    email_verified => 1,
);

my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    email       => $email,
});

my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email,
});

my $client_mx2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email,
});

my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email,
});

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});

$user->add_client($client_mx);
$user->add_client($client_mx2);
$user->add_client($client_mlt);
$user->add_client($client_mf);
$user->add_client($client_vr);

subtest 'Social responsibility status removal' => sub {

    # set status for the clients
    $client_mx->status->set('unwelcome', 'system', 'Social responsibility thresholds breached - Pending financial assessment');
    $client_mx2->status->set('unwelcome', 'system', 'Social responsibility thresholds breached - Random String');
    $client_mlt->status->set('unwelcome', 'system', 'Social responsibility thresholds breached - Pending financial assessment');

    # check clients FA

    #FA not completed
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('is_financial_assessment_complete' => sub { return 0 });

    ok !$client_mlt->is_financial_assessment_complete, 'MLT is not FA completed';
    ok !$client_mx->is_financial_assessment_complete,  'MX is not FA completed';
    ok !$client_mx2->is_financial_assessment_complete, 'MX2 is not FA completed';

    $client_mlt->update_status_after_auth_fa;

    undef $client_mx->{status};
    undef $client_mx2->{status};
    undef $client_mlt->{status};

    ok $client_mlt->status->unwelcome, "Status was not removed for the MLT client";
    ok $client_mx->status->unwelcome,  "Status was not removed for the MX client";
    ok $client_mx2->status->unwelcome, "Status was not removed for the MX2 client with another reason";

    #FA completed
    $mocked_client->mock('is_financial_assessment_complete' => sub { return 1 });

    ok $client_mlt->is_financial_assessment_complete, 'MLT is FA completed';
    ok $client_mx->is_financial_assessment_complete,  'MX is FA completed';
    ok $client_mx2->is_financial_assessment_complete, 'MX2 is FA completed';

    $client_mlt->update_status_after_auth_fa;

    undef $client_mx->{status};
    undef $client_mx2->{status};
    undef $client_mlt->{status};

    ok !$client_mlt->status->unwelcome, "Status was removed for the MLT client";
    ok !$client_mx->status->unwelcome,  "Status was removed for the MX client";
    ok $client_mx2->status->unwelcome, "Status was not removed for the MX2 client with another reason";

    $mocked_client->unmock_all();
};

subtest 'MLT unwelcome status (after first deposit) removal' => sub {
    # set status for the clients
    $_->status->upsert('unwelcome', 'system', 'Age verification is needed after first deposit.') for ($client_mlt, $client_mx, $client_mf);
    $_->status->clear_age_verification                                                           for ($client_mlt, $client_mx, $client_mf);

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $fa_completed  = 0;
    $mocked_client->mock('is_financial_assessment_complete' => sub { return $fa_completed });
    my $authenticated = 0;
    $mocked_client->mock('fully_authenticated' => sub { return $authenticated });

    $client_mf->update_status_after_auth_fa;
    undef $_->{status}                                                             for ($client_mlt, $client_mx, $client_mf);
    ok($_->status->unwelcome, "Status was not removed form client " . $_->loginid) for ($client_mlt, $client_mx, $client_mf);

    $_->status->set('age_verification', 'system', 'test') for ($client_mlt, $client_mx);
    $client_mf->update_status_after_auth_fa;
    undef $_->{status} for ($client_mlt, $client_mx, $client_mf);
    ok(!$_->status->unwelcome, "Status was removed after age verification form client " . $_->loginid) for ($client_mlt, $client_mx);
    ok($client_mf->status->unwelcome, "Status was not removed for the non-age verified client");

    # different reason
    $client_mlt->status->upsert('unwelcome', 'system', 'Any other reason');
    $client_mlt->update_status_after_auth_fa;
    undef $client_mlt->{status};
    ok($client_mlt->status->unwelcome, "Status unwelcome was not removed when reason was different");

    $mocked_client->unmock_all();
};

subtest 'VR age_verification for GB clients' => sub {

    $_->status->clear_age_verification for ($client_mx, $client_vr);

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $residence     = 'gb';
    $mocked_client->mock(residence => sub { return $residence });

    $client_mx->status->set('age_verification', 'system', 'test');
    $client_mx->update_status_after_auth_fa;
    undef $_->{status} for ($client_mx, $client_vr);
    ok $client_vr->status->age_verification, 'VR client is age verified';

    $mocked_client->unmock_all();
};

done_testing();
