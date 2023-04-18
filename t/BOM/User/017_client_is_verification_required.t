use strict;
use warnings;

use Test::More  qw(no_plan);
use Test::Fatal qw(lives_ok);
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Client;
use BOM::User;

my $email = 'abc@binary.com';

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

is($client_mx->is_verification_required(), 0, 'authentication is not required if age verified and fully auth');

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

is($client_mx->is_verification_required(), 1, 'return 1 because LC is maltainvest');

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

done_testing();
