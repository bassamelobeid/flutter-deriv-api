use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Customer;

use BOM::User::Client;
use BOM::User::Password;
use BOM::User::FinancialAssessment qw(update_financial_assessment);

my $test_customer = BOM::Test::Customer->create(
    clients => [{
            name        => 'VRTC',
            broker_code => 'VRTC',
        },
        {
            name        => 'MF',
            broker_code => 'MF',
        }]);
my $client_vr = $test_customer->get_client_object('VRTC');
my $client_mf = $test_customer->get_client_object('MF');

subtest 'Social responsibility status removal' => sub {

    # set status for the clients
    $client_mf->status->set('unwelcome', 'system', 'Social responsibility thresholds breached - Pending financial assessment');

    # check clients FA

    #FA not completed
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('is_financial_assessment_complete' => sub { return 0 });

    ok !$client_mf->is_financial_assessment_complete, 'mf is not FA completed';
    undef $client_mf->{status};

    ok $client_mf->status->unwelcome, "Status was not removed for the MF client";

    #FA completed
    $mocked_client->mock('is_financial_assessment_complete' => sub { return 1 });

    ok $client_mf->is_financial_assessment_complete, 'MF is FA completed';
    $client_mf->update_status_after_auth_fa;

    undef $client_mf->{status};

    ok !$client_mf->status->unwelcome, "Status was removed for the MF client";

    $mocked_client->unmock_all();
};

subtest 'MF unwelcome status (after first deposit) removal' => sub {
    # set status for the clients
    $client_mf->status->upsert('unwelcome', 'system', 'Age verification is needed after first deposit.');
    $client_mf->status->clear_age_verification;

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $fa_completed  = 0;
    $mocked_client->mock('is_financial_assessment_complete' => sub { return $fa_completed });
    my $authenticated = 0;
    $mocked_client->mock('fully_authenticated' => sub { return $authenticated });

    $client_mf->update_status_after_auth_fa;
    undef $client_mf->{status};
    ok($client_mf->status->unwelcome, "Status was not removed form client " . $client_mf->loginid);

    $client_mf->status->set('age_verification', 'system', 'test');
    $client_mf->update_status_after_auth_fa;
    undef $client_mf->{status};
    ok(!$client_mf->status->unwelcome, "Status was removed after age verification form client " . $client_mf->loginid);
    # different reason
    $client_mf->status->upsert('unwelcome', 'system', 'Any other reason');
    $client_mf->update_status_after_auth_fa;
    undef $client_mf->{status};
    ok($client_mf->status->unwelcome, "Status unwelcome was not removed when reason was different");

    $mocked_client->unmock_all();
};

subtest 'VR age_verification for GB clients' => sub {

    $_->status->clear_age_verification for ($client_mf, $client_vr);

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $residence     = 'gb';
    $mocked_client->mock(residence => sub { return $residence });

    $client_mf->status->set('age_verification', 'system', 'test');
    $client_mf->update_status_after_auth_fa;
    undef $_->{status} for ($client_mf, $client_vr);
    ok $client_vr->status->age_verification, 'VR client is age verified';

    $mocked_client->unmock_all();
};

subtest 'Name change after first deposit' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'namechange@test.com',
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test',
    )->add_client($client);

    $client->status->set('withdrawal_locked', 'system', 'Excessive name changes after first deposit - pending POI');
    undef $client->{status};
    $client->update_status_after_auth_fa();
    undef $client->{status};
    ok $client->status->withdrawal_locked, 'retain withdrawal_locked if not age verified';

    $client->status->set('age_verification', 'system', 'testing');
    undef $client->{status};
    $client->update_status_after_auth_fa();
    undef $client->{status};
    ok !$client->status->withdrawal_locked, 'withdrawal_locked removed when age verified';

    $client->status->set('withdrawal_locked', 'system', 'other reason');
    undef $client->{status};
    $client->update_status_after_auth_fa();
    undef $client->{status};
    ok $client->status->withdrawal_locked, 'retain withdrawal_locked for other reason';
};

subtest 'DIEL after authentication status removal' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'MF',
                broker_code => 'MF',
            }]);
    my $client = $test_customer->get_client_object('MF');

    #FA not completed
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('is_financial_assessment_complete' => sub { return 0 });
    $mocked_client->mock('fully_authenticated'              => sub { return 1 });

    $client->status->set('unwelcome',         'system', 'Client Deposited - Pending Authentication');
    $client->status->set('withdrawal_locked', 'system', 'Client Deposited - Pending Authentication');

    $client->update_status_after_auth_fa;
    undef $client->{status};
    ok $client->status->unwelcome,         'unwelcome status not removed when FA not completed even when fully authenticated';
    ok $client->status->withdrawal_locked, 'withdrawal_locked status not removed when FA not completed even when fully authenticated';

    $mocked_client->mock('is_financial_assessment_complete' => sub { return 1 });
    $mocked_client->mock('fully_authenticated'              => sub { return 0 });

    $client->update_status_after_auth_fa;
    undef $client->{status};
    ok $client->status->unwelcome,         'unwelcome status not removed when FA completed but not fully authenticated';
    ok $client->status->withdrawal_locked, 'withdrawal_locked status not removed when FA completed but not fully authenticated';

    $mocked_client->mock('is_financial_assessment_complete' => sub { return 1 });
    $mocked_client->mock('fully_authenticated'              => sub { return 1 });

    $client->update_status_after_auth_fa;
    undef $client->{status};
    ok !$client->status->unwelcome,         'unwelcome status removed when FA completed and fully authenticated';
    ok !$client->status->withdrawal_locked, 'withdrawal_locked status removed when FA completed and fully authenticated';

    #Checking the other reason
    $client->status->set('unwelcome',             'system', 'Pending authentication or FA');
    $client->status->set('allow_document_upload', 'system', 'Pending authentication or FA');

    $client->update_status_after_auth_fa;
    undef $client->{status};

    ok !$client->status->allow_document_upload, 'allow document upload status removed when FA completed and when fully authenticated';
    ok !$client->status->withdrawal_locked,     'withdrawal_locked status not removed when FA not completed and when fully authenticated';
};

done_testing();
