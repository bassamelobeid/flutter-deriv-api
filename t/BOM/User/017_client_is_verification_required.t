use strict;
use warnings;

use Test::More  qw(no_plan);
use Test::Fatal qw(lives_ok);
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Client;
use BOM::User;

my $email      = 'abc@binary.com';
my $email_diel = 'abcd@binary.com';

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email,
    residence   => 'gb',
});

my $user = BOM::User->create(
    email    => $email,
    password => 'test',
);

my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email,
    residence   => 'za',
});

my $user_diel = BOM::User->create(
    email    => $email_diel,
    password => 'test',
);

$user_diel->add_client($client_mf);
$user->add_client($client_vr);
$user->add_client($client_mx);

is($client_vr->is_verification_required(), 0, "vr client does not need verification");

my $mock_lc = Test::MockModule->new('LandingCompany');
$mock_lc->mock('skip_authentication', sub { 1 });

my $mock_cc                                    = Test::MockModule->new('Brands::Countries');
my $skip_deposit_verif                         = 0;
my $require_verification_when_not_age_verified = 1;

$mock_cc->mock(
    'countries_list',
    sub {
        my $list = $mock_cc->original('countries_list')->(@_);

        return +{
            map {
                (
                    $_ => +{
                        $list->{$_}->%*,
                        skip_deposit_verification                  => $skip_deposit_verif,
                        require_verification_when_not_age_verified => $require_verification_when_not_age_verified
                    })
            } keys $list->%*
        };
    });

my $mock_cli = Test::MockModule->new(ref($client_mx));

is($client_mx->is_verification_required(), 0, 'authentication is not required if landing company skip_authentication flag is set');

$mock_lc->mock('skip_authentication', sub { 0 });

$client_mx->set_authentication_and_status('ID_DOCUMENT', 'test');

is($client_mx->is_verification_required(), 0,     'authentication is not required if age verified and fully auth');
is($client_mx->mifir_id,                   undef, 'mifir id is not set');

$mock_lc->unmock_all;
$client_mx->status->clear_age_verification;

$client_mx->set_authentication_and_status('NEEDS_ACTION', 'test');
is($client_mx->is_verification_required(check_authentication_status => 1),
    1, "check_authentication_status in gb and auth status in needs action will require verification");

$client_mx->set_authentication_and_status('IDV', 'test');
is($client_mx->is_verification_required(check_authentication_status => 1),
    1, "check_authentication_status in gb and no id_online will require verification");

is($client_mx->is_verification_required(risk_sr => 'high'), 1, "authentication required if client is considered high risk");
$client_mx->status->set('unwelcome', 'system', 'testing');
is($client_mx->is_verification_required(risk_aml => 'high'), 1, "authentication required if client is considered high risk");

$mock_cli->mock('has_deposits', sub { 1 });

is($client_mx->is_verification_required(), 1, "check_authentication_status has deposits");

$skip_deposit_verif = 1;
is($client_mx->is_verification_required(), 1, 'return 1 if age verification is required');

$require_verification_when_not_age_verified = 0;
$mock_lc->mock(
    'short',
    sub {
        return 'maltainvest';
    });

$mock_lc->mock(
    'short',
    sub {
        return 'malta';
    });

my $user_mock = Test::MockModule->new(ref($user));
$user_mock->mock(
    'has_mt5_regulated_account',
    sub {
        return 1;
    });

is($client_mx->is_verification_required(has_mt5_regulated_account => 1), 1, 'return 1 because it has mt5 regulated account');

$user_mock->mock(
    'has_mt5_regulated_account',
    sub {
        return 0;
    });

is($client_mx->is_verification_required(), 0, 'return 0 because it does not have mt5 regulated account');

my $mock_cli_diel  = Test::MockModule->new(ref($client_mf));
my $user_mock_diel = Test::MockModule->new(ref($user_diel));

$mock_lc->unmock_all;
$mock_lc->mock(
    'short',
    sub {
        return 'maltainvest';
    });

$mock_cli_diel->mock('has_deposits', sub { 0 });

$user_mock_diel->mock(
    'has_mt5_regulated_account',
    sub {
        return 1;
    });

is($client_mf->is_verification_required(has_mt5_regulated_account => 1),
    0, 'return 0 because it has mt5 regulated account(maltainvest) w/o deposit accoriding to new DIEL flow');

$mock_cli_diel->mock('has_deposits', sub { 1 });

is($client_mf->is_verification_required(has_mt5_regulated_account => 1),
    1, 'return 1 because it has mt5 regulated account(maltainvest) with deposit accoriding to new DIEL flow');

$mock_lc->mock(
    'short',
    sub {
        return 'labuan';
    });

is($client_mf->is_verification_required(has_mt5_regulated_account => 1),
    1, 'return 1 because it has mt5 regulated account except for maltainvest irrespective of deposit');

$client_mf->set_authentication_and_status('ID_DOCUMENT', 'test');
ok($client_mf->mifir_id, 'mifir id is set');

subtest 'update mifir id' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test',
    )->add_client($client);

    is(defined($client->mifir_id), "", 'mifir id is not set');
    $client->update_mifir_id();
    ok($client->mifir_id, 'mifir id is set');
    is($client->mifir_id, 'AT19780623BRAD#PITT#', 'mifir id is correct');
    $client->first_name('Grad');
    $client->update_mifir_id();
    is($client->mifir_id, 'AT19780623BRAD#PITT#', 'mifir id is not changed if already set');
    $client->mifir_id(undef);
    $client->citizen('us');
    $client->update_mifir_id();
    is($client->mifir_id, undef, 'mifir id is not changed if citizenship is not part of eu set');
    $client->citizen('za');
    $client->set_authentication_and_status('ID_DOCUMENT', 'test');
    is($client->mifir_id, 'ZA19780623GRAD#PITT#', 'mifir id is set for diel  if not already set');
    $client->mifir_id(undef);
    $client->citizen('sk');
    $user_mock->mock(
        'get_onfido_user_reports',
        sub {
            return {
                'national_identity_card' => {
                    "gender"           => "Female",
                    "document_type"    => "national_identity_card",
                    "document_numbers" => [{
                            "type"  => "document_number",
                            "value" => "HU111111"
                        },
                        {
                            "type"  => "personal_number",
                            "value" => "1111111111"
                        }]}};
        });
    $client->set_authentication_and_status('ID_DOCUMENT', 'test');
    is($client->mifir_id, 'SK1111111111', 'mifir id is set for with document_number');
    $client->mifir_id(undef);
    $client->citizen('cy');
    $user_mock->mock(
        'get_onfido_user_reports',
        sub {
            return {
                'passport' => {
                    "gender"           => "Female",
                    "document_type"    => "passport",
                    "document_numbers" => [{
                            "type"  => "document_number",
                            "value" => "111111"
                        },
                        {
                            "type"  => "personal_number",
                            "value" => "1111111111"
                        }]}};
        });
    $client->set_authentication_and_status('ID_DOCUMENT', 'test');
    is($client->mifir_id, 'CY111111', 'mifir id is set for with personal_number');
    $client->citizen(undef);
    is($client->update_mifir_id(), 0, 'should return false if there is no citizenship');
};
done_testing();
