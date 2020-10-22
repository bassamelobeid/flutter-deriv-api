use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Guard;
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Platform::Context::Request;

my $app_config = BOM::Config::Runtime->instance->app_config;
my $orig_config = $app_config->cgi->terms_conditions_versions;
scope_guard { $app_config->cgi->terms_conditions_versions($orig_config) };
$app_config->cgi->terms_conditions_versions('{ "binary": "Version 1 2020-01-01", "deriv": "Version 2 2020-06-01" }');

my $mock_lc = Test::MockModule->new('LandingCompany');

my $user = BOM::User->create(
    email    => 'tnc@test.com',
    password => 'test',
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code=>'VRTC'});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code=>'CR'});
$user->add_client($client_vr);
$user->add_client($client_cr);

my $r = BOM::Platform::Context::Request->new({brand_name=>'binary'});
BOM::Platform::Context::request($r);

ok !$client_vr->is_tnc_approval_required, 'vr does not need tnc';

$mock_lc->mock(tnc_required => sub { 0 });
ok !$client_cr->is_tnc_approval_required, 'real client does not need tnc if lc does not need it';

$mock_lc->mock(tnc_required => sub { 1 });
ok $client_cr->is_tnc_approval_required, 'real client needs tnc if lc does';
is $client_cr->accepted_tnc_version, '', 'No tnc accepted yet';
is $client_cr->user->current_tnc_version, 'Version 1 2020-01-01', 'correct version from config and brand';

$client_cr->user->set_tnc_approval();
ok !$client_cr->is_tnc_approval_required, 'client does not need tnc after accepting';
is $client_cr->accepted_tnc_version, 'Version 1 2020-01-01', 'Client accepted version';
is $client_vr->accepted_tnc_version, '', 'vr client has no accepted t&c version';

$r = BOM::Platform::Context::Request->new({brand_name=>'deriv'});
BOM::Platform::Context::request($r);

ok $client_cr->is_tnc_approval_required, 'client needs tnc for new brand';
is $client_cr->accepted_tnc_version, '', 'No tnc accepted for new brand';
$client_cr->user->set_tnc_approval();
ok !$client_cr->is_tnc_approval_required, 'client does not need tnc after accepting';
is $client_cr->accepted_tnc_version, 'Version 2 2020-06-01', 'Client accepted version for new brand';
is $client_vr->accepted_tnc_version, '', 'vr client still has no accepted t&c version';

$app_config->cgi->terms_conditions_versions('{ "deriv": "Version 3 2020-07-01" }');

ok $client_cr->is_tnc_approval_required, 'client needs tnc after version increased';

$r = BOM::Platform::Context::Request->new({brand_name=>'binary'});
BOM::Platform::Context::request($r);

ok !$client_cr->is_tnc_approval_required, 'client does not need tnc if brand has no tnc version';

done_testing;
