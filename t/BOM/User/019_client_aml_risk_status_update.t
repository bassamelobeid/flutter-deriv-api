use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test::Helper::FinancialAssessment;

use BOM::User;
use BOM::User::Client;
use BOM::User::Script::AMLClientsUpdate;
use BOM::User::Password;
use BOM::User::FinancialAssessment qw(update_financial_assessment);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
populate_exchange_rates();

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');

# Since the database function get_recent_high_risk_clients fails in circleci (because of the included dblink),
# database access method is mocked here, returning a predefined expected result.
my $mock_aml = Test::MockModule->new("BOM::User::Script::AMLClientsUpdate");
my $expected_db_rows;
$mock_aml->mock(
    _get_recent_high_risk_clients => sub {
        return $expected_db_rows;
    });

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

$user->add_client($client_vr);
$user->add_client($client_cr);
$user->add_client($client_cr2);

my $res;

my $c = BOM::User::Script::AMLClientsUpdate->new();

my @emitted_args;
my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mocked_emitter->redefine(
    emit => sub {
        @emitted_args = @_;
    });

subtest 'low aml risk client CR company' => sub {
    my $landing_company = 'CR';
    $client_cr->aml_risk_classification('high');
    $res = $client_cr->save;
    $client_cr->aml_risk_classification('low');
    $res = $client_cr->save;

    is($client_cr->aml_risk_classification, 'low', "aml risk is low");

    $expected_db_rows = [];
    my $aml_high_clients = $c->update_aml_high_risk_clients_status($landing_company);
    ok(!@$aml_high_clients, 'no client found having aml risk high.');
    ok !$client_cr->status->withdrawal_locked, 'client is not withdrawal-locked';

    clear_clients($client_cr);
};

subtest 'aml risk becomes high CR landing company' => sub {
    my $landing_company = 'CR';

    #no matter what client aml risk was previously, its latest should be high to be able to picked up
    $client_cr->aml_risk_classification('high');
    $client_cr->save;
    $client_cr->status->clear_withdrawal_locked;

    $expected_db_rows = [{login_ids => $client_cr->loginid}];
    my $result = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, 1, 'Correct number of affected users';
    is_deeply $result, [{login_ids => $client_cr->loginid}], 'Returned client ids are correct';

    ok $client_cr->status->withdrawal_locked,     "client is withdrawal_locked";
    ok $client_cr->status->allow_document_upload, "client is allow_document_upload";
    is $client_cr->status->withdrawal_locked->{reason},     'Pending authentication or FA';
    is $client_cr->status->allow_document_upload->{reason}, 'BECOME_HIGH_RISK';

    ok !$client_cr2->status->withdrawal_locked, "sibling account is not withdrawal_locked";
    ok $client_cr2->status->allow_document_upload, "slbling account is allow_document_upload";

    $expected_db_rows = [];
    $result           = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, 0, 'No result after withdrawal locked';

    $client_cr->status->clear_withdrawal_locked();
    $client_cr->status->clear_allow_document_upload();
    $client_cr2->status->clear_withdrawal_locked();
    $client_cr2->status->clear_allow_document_upload();

    #Two high risk siblings
    $client_cr2->aml_risk_classification('high');
    $client_cr2->save;

    $expected_db_rows = [{login_ids => join(',', sort($client_cr->loginid, $client_cr2->loginid))}];
    $result           = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, @$expected_db_rows, 'Correct number of affected users';
    is_deeply $result, $expected_db_rows, 'Returned client ids are correct';

    ok $client_cr->status->withdrawal_locked,      "client is withdrawal_locked";
    ok $client_cr->status->allow_document_upload,  "client is allow_document_upload";
    ok $client_cr2->status->withdrawal_locked,     "sibling account is withdrawal_locked";
    ok $client_cr2->status->allow_document_upload, "slbling account is allow_document_upload";

    clear_clients($client_cr, $client_cr2);
};

subtest 'manual override high classifications are excluded' => sub {
    my $landing_company = 'CR';

    #no matter what client aml risk was previously, its latest should be high to be able to picked up
    $client_cr->aml_risk_classification('manual override - high');
    $client_cr->save;

    my $result = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, 0, 'Manual override high risk classification is filtered out';

    ok !$client_cr->status->withdrawal_locked,     "client is not withdrawal_locked";
    ok !$client_cr->status->allow_document_upload, "client is not allow_document_upload";

    clear_clients($client_cr, $client_cr2);
};

subtest 'filter by authentication and financial_assessment' => sub {
    $client_cr->aml_risk_classification('high');
    $client_cr->save;
    $client_cr2->aml_risk_classification('high');
    $client_cr2->save;

    # database returns the same rows throughout this subtest
    $expected_db_rows = [{login_ids => join(',', sort($client_cr->loginid, $client_cr2->loginid))}];

    my $landing_company = 'CR';
    $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_cr->save();
    $client_cr2->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_cr2->save();
    ok $client_cr->fully_authenticated,  'The account is fully authenticated';
    ok $client_cr2->fully_authenticated, 'Sibling account is fully authenticated';

    my $result = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, @$expected_db_rows, 'Correct number of affected users';
    is_deeply $result, $expected_db_rows, 'Authenticated clients with incomplete FA are not filtered out';
    $client_cr->status->clear_withdrawal_locked();
    $client_cr2->status->clear_withdrawal_locked();

    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client_cr2->financial_assessment({
        data => encode_json_utf8($data),
    });
    $client_cr2->save();

    ok !$client_cr->is_financial_assessment_complete, 'The account is not FA completed';
    ok $client_cr2->is_financial_assessment_complete, 'Sibling account is FA completed';
    $result = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, 1, 'Correct number of affected users';
    is_deeply $result, [{login_ids => $client_cr->loginid}], 'Client with both authentication and financial_assessment is filtered out';

    $client_cr->status->clear_withdrawal_locked();

    my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    $mocked_documents->mock('expired' => sub { return 1 });
    $result = $c->update_aml_high_risk_clients_status($landing_company);
    is @$result, @$expected_db_rows, 'Correct number of affected users';
    is_deeply $result, $expected_db_rows, 'No client is filtered if documents are expired';
    $mocked_documents->unmock_all;

    clear_clients($client_cr, $client_cr2);
};

subtest 'withdrawal lock auto removal after authentication and FA' => sub {
    $_->aml_risk_classification('high') for ($client_cr, $client_cr2);
    my $mocked_client    = Test::MockModule->new('BOM::User::Client');
    my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my @called_for_clients;
    $mocked_client->mock(
        update_status_after_auth_fa => sub {
            push @called_for_clients, $_[0]->loginid;
            return $mocked_client->original('update_status_after_auth_fa')->(@_);
        });

    $client_cr->status->set('withdrawal_locked',     'system', 'Pending authentication or FA');
    $client_cr->status->set('allow_document_upload', 'system', 'BECOME_HIGH_RISK');
    $client_cr2->status->setnx('withdrawal_locked',     'system', 'Pending authentication or FA');
    $client_cr2->status->setnx('allow_document_upload', 'system', 'Pending authentication or FA');
    # financial assessment complete, unauthenticated
    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    update_financial_assessment($user, $data);
    undef $client_cr->{financial_assessment};    # let it be reloaded from database
    ok $client_cr->is_financial_assessment_complete, 'financial_assessment completed';
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok $client_cr->status->withdrawal_locked,     'client is still withdrawal-locked (not authenticated yet)';
    ok $client_cr->status->allow_document_upload, 'client is still allow_document_upload (not authenticated yet)';
    undef @called_for_clients;

    # financial assessment incomplete, authenticated
    $client_cr->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client_cr->save;
    ok $client_cr->fully_authenticated, 'client is authenticated';
    is @called_for_clients, 1, 'update_status_after_auth_fa is called for authentication';
    undef @called_for_clients;

    for ($client_cr, $client_cr2) {
        $_->financial_assessment({data => '{}'});
        $_->save;
    }
    update_financial_assessment($user, {});
    undef $client_cr->{financial_assessment};
    is $client_cr->is_financial_assessment_complete, 0, 'FA is not complete';
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok $client_cr->status->withdrawal_locked, 'client is still withdrawal-locked (fa is incomplete)';
    ok !$client_cr->status->allow_document_upload, 'client has not allow_document_upload, (authenticated)';
    undef @called_for_clients;

    # financial assessment incompelete, authenticated, different reason
    $client_cr->status->setnx('withdrawal_locked', 'system', 'Some reason');
    update_financial_assessment($user, $data);
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok $client_cr->status->withdrawal_locked, 'withdrawal is locked for another reason - cannot be auto-removed';
    undef @called_for_clients;

    # financial assessment incompelete, authenticated, correct reason
    $client_cr->status->clear_withdrawal_locked;
    $client_cr->status->clear_allow_document_upload;
    $client_cr->status->set('withdrawal_locked',     'system', 'Pending authentication or FA');
    $client_cr->status->set('allow_document_upload', 'system', 'BECOME_HIGH_RISK');
    $client_cr->{status}  = undef;
    $client_cr2->{status} = undef;
    update_financial_assessment($user, $data);
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok !$client_cr->status->withdrawal_locked,      'withdrawal lock is auto-removed by financial_assessment';
    ok !$client_cr->status->allow_document_upload,  'allow_document_upload is auto-removed by financial_assessment';
    ok !$client_cr2->status->withdrawal_locked,     'withdrawal lock is auto-removed by financial_assessment';
    ok !$client_cr2->status->allow_document_upload, 'allow_document_upload is auto-removed by financial_assessment';
    undef @called_for_clients;

    #direct call (as done in backoffice upon authentication)
    $client_cr->status->clear_withdrawal_locked;
    $client_cr->status->set('withdrawal_locked', 'system', 'Pending authentication or FA');
    $client_cr->status->clear_allow_document_upload;
    $client_cr->status->set('allow_document_upload', 'system', 'BECOME_HIGH_RISK');
    $client_cr2->status->set('withdrawal_locked', 'system', 'Pending authentication or FA');
    $client_cr2->status->clear_allow_document_upload;
    $client_cr2->status->set('allow_document_upload', 'system', 'Pending authentication or FA');
    $client_cr->{status}  = undef;
    $client_cr2->{status} = undef;
    $client_cr->update_status_after_auth_fa();
    ok !$client_cr->status->withdrawal_locked,      'withdrawal lock is auto-removed by calling update_status_after_auth_fa';
    ok !$client_cr->status->allow_document_upload,  'allow_document_upload is auto-removed by financial_assessment';
    ok !$client_cr2->status->withdrawal_locked,     'withdrawal lock is auto-removed by financial_assessment';
    ok !$client_cr2->status->allow_document_upload, 'allow_document_upload is auto-removed by financial_assessment';
    undef @called_for_clients;

    # financial assessment incomplete, authenticated, correct reason, expired documents
    $mocked_documents->mock('expired' => sub { return 1 });
    $client_cr->status->set('withdrawal_locked', 'system', 'Pending authentication or FA');
    update_financial_assessment($user, $data);
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok $client_cr->status->withdrawal_locked, 'client is still withdrawal-lock (documents expired)';
    undef @called_for_clients;

    # financial assessment incomplete, forced
    clear_clients($client_cr);

    $client_cr->status->set('financial_assessment_required', 'felan',  'Financial Assessment completion is forced from Backoffice.');
    $client_cr->status->set('withdrawal_locked',             'system', 'FA needs to be completed');
    $client_cr->update_status_after_auth_fa();
    ok $client_cr->status->financial_assessment_required, 'financial_assessment_required not removed, correct action';
    like $client_cr->status->withdrawal_locked->{reason}, qr/FA needs to be completed/,
        'withdrawal_locked with "FA needs to be completed" reason not removed, correct action';
    undef @called_for_clients;

    #financial assessment complete, flags should get removed
    $client_cr->{status} = undef;
    update_financial_assessment($user, $data);
    is @called_for_clients, 1, 'update_status_after_auth_fa called automatically by financial assessment';
    ok !$client_cr->status->financial_assessment_required, 'financial_assessment_required removed because FA completed';
    ok !$client_cr->status->withdrawal_locked,             'withdrawal_locked with "FA needs to be completed" message removed because FA completed';
    undef @called_for_clients;

    $mocked_client->unmock_all;
    $mocked_documents->unmock_all;
};

subtest 'AML risk update' => sub {
    my $user_cr = BOM::User->create(
        email    => 'aml_risk_update_cr@deriv.com',
        password => 'password',
    );
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $user_cr->email,
        binary_user_id => $user_cr->id,
        residence      => 'br'
    });
    $client_cr->set_default_account('EUR');
    $client_cr->save;
    $user_cr->add_client($client_cr);

    my $user_mf = BOM::User->create(
        email    => 'aml_risk_update_mf@deriv.com',
        password => 'password',
    );
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        email          => $user_mf->email,
        binary_user_id => $user_mf->id,
        residence      => 'es'
    });
    $client_mf->set_default_account('EUR');
    $client_mf->save;

    $user_mf->add_client($client_mf);

    my @emails;
    my $mock_script = Test::MockModule->new('BOM::User::Script::AMLClientsUpdate');
    $mock_script->redefine(send_email => sub { my $args = shift; push @emails, $args });

    my %mock_data = map { $_->binary_user_id => [$_->loginid] } ($client_cr, $client_mf);
    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(loginids => sub { return $mock_data{shift->id}->@* });

    is exception { $c->aml_risk_update() }, undef, 'AML risk update is executed without any error';
    $client_cr->load;
    is $client_cr->aml_risk_classification, 'low', 'Risk classification is low: no deposits yet';
    is scalar @emails, 0, 'No email is sent';

    subtest 'transaction thresholds' => sub {

        my $thresholds = {
            CR => {
                yearly_standard => 10,
                yearly_high     => 20
            },
            MF => {
                yearly_standard => 10,
                yearly_high     => 20
            },
            revision => 1
        };

        my $mock_config = Test::MockModule->new('BOM::Config::Compliance');
        $mock_config->redefine(
            get_risk_thresholds          => $thresholds,
            get_jurisdiction_risk_rating => {});

        BOM::Test::Helper::Client::top_up($client_cr, 'EUR', 9);
        update_payment_dates($client_cr);
        $c->aml_risk_update();
        $client_cr->load;
        is $client_cr->aml_risk_classification, 'low', 'Risk classification is low: balance less than threshold';
        is scalar @emails, 0, 'No email is sent';

        BOM::Test::Helper::Client::top_up($client_cr, 'EUR', 1);
        update_payment_dates($client_cr);
        $c->aml_risk_update();
        $client_cr->load;
        is $client_cr->aml_risk_classification, 'standard', 'Risk classification changed to standard: balance crossed the standard threshold';
        is scalar @emails, 0, 'No email is sent for standard risk level';

        BOM::Test::Helper::Client::top_up($client_cr, 'EUR', 10);
        update_payment_dates($client_cr);
        $c->aml_risk_update();
        $client_cr->load;
        is $client_cr->aml_risk_classification, 'high', 'Risk classification changed to high: balance crossed the high threshold';
        is scalar @emails, 1, 'An email is sent for the high risk client';

        my $mail    = $emails[0];
        my $user_id = $user_cr->id;
        like $mail->{subject}, qr/Daily AML risk update/, 'email subject is correct';
        my $loginid = $client_cr->loginid;
        ok $mail->{message}->[0] =~ qr/$loginid/, 'loginids is found in email content';
        ok $mail->{message}->[0] !~ qr/MF\d/, 'No MF loginid found in email content';
    };

    subtest 'jurisdiction ratings' => sub {
        my $jurisdiction = {
            standard => [qw/br/],
            high     => [qw/es ru/],
            revision => 1,
        };

        my $mock_config = Test::MockModule->new('BOM::Config::Compliance');
        $mock_config->redefine(
            get_risk_thresholds          => {},
            get_jurisdiction_risk_rating => $jurisdiction
        );
        my $mock_landing_company = Test::MockModule->new('LandingCompany');
        $mock_landing_company->redefine(jurisdiction_risk_ratings => 0);

        $client_cr->aml_risk_classification('low');
        $client_mf->aml_risk_classification('low');
        $client_cr->save();
        $client_mf->save();
        undef @emails;

        my $c = BOM::User::Script::AMLClientsUpdate->new();
        $c->aml_risk_update();
        $client_cr->load;
        $client_mf->load;
        is $client_cr->aml_risk_classification, 'low', 'CR risk classification is not changed';
        is $client_mf->aml_risk_classification, 'low', 'MF risk classification is not changed';
        is scalar @emails, 0, 'No email is sent';

        $mock_landing_company->redefine(jurisdiction_risk_ratings => 1);

        $c = BOM::User::Script::AMLClientsUpdate->new();
        $c->aml_risk_update();
        $client_cr->load;
        $client_mf->load;
        is $client_cr->aml_risk_classification, 'standard', 'CR risk classification changed to standard by the jurisdiction rating';
        is $client_mf->aml_risk_classification, 'high',     'MF risk classification changed to high by the jurisdiction rating';

        is scalar @emails, 1, 'An email is sent for the high risk client';

        my $mail    = $emails[0];
        my $user_id = $user_mf->id;
        like $mail->{subject}, qr/Daily AML risk update/, 'email subject is correct';
        my $loginid = $client_mf->loginid;
        ok $mail->{message}->[0] =~ qr/$loginid/, 'loginids is found in email content';
        ok $mail->{message}->[0] !~ qr/CR\d/, 'No CR loginid found in email content';

        $mock_landing_company->unmock_all;
        $mock_config->unmock_all;
    };

    $mock_script->unmock_all;
    $mock_user->unmock_all;
};

sub update_payment_dates {
    my $client = shift;

    # payments of the corrent day are ignored by update_aml_risk function;
    # so we've got to move them at least one day back.

    my $yesterday = Date::Utility->new->minus_time_interval('1d');

    $client->dbh->do('UPDATE payment.payment SET payment_time = ? WHERE account_id = ?', undef, $yesterday->date_yyyymmdd, $client->account->id);
}

sub clear_clients {
    for my $client (@_) {
        $client->status->clear_financial_assessment_required();
        $client->status->clear_withdrawal_locked();
        $client->status->clear_allow_document_upload();
        $client->set_authentication('ID_DOCUMENT', {status => 'pending'});
        $client->financial_assessment({data => '{}'});
        $client->aml_risk_classification('low');
        $client->save;
    }
}

$mock_aml->unmock_all;

done_testing();

