use strict;
use warnings;

use Test::Most;
use Test::MockModule;

use Data::Dumper;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::RPC::v3::Utility;

use utf8;

my $client;
my $auth_result;

subtest 'Initialization' => sub {
    plan tests => 1;

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
    }
    'Initial accounts';
};

my $module = Test::MockModule->new('BOM::Platform::Context::Request');
$module->mock('_build_language', sub { 'EN' });

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization() } 'Should return result of check';

is_deeply $auth_result->{error}->{code}, 'AuthorizationRequired', 'It should return error: AuthorizationRequired';

lives_ok {
    $client->set_status('disabled', 'test', 'test');
    $client->save;
}
'Disable client';

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) } 'Should return result of check';

is $auth_result->{error}->{code}, 'DisabledClient', 'It should return error: DisabledClient';

lives_ok {
    $client->clr_status('disabled');
    $client->set_status('duplicate_account', 'test', 'test');
    $client->save;
}
'Duplicate client';

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) } 'Should return result of check';

is $auth_result->{error}->{code}, 'DisabledClient', 'It should return error: DisabledClient';

my $timeout_until      = Date::Utility->new->plus_time_interval('1d');
my $timeout_until_date = $timeout_until->date;
lives_ok {
    $client->clr_status('duplicate_account');
    $client->set_exclusion->timeout_until($timeout_until->epoch);
    $client->save;
}
'Enable client and exclude him until tomorrow';
lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) } 'Should return result of check';
is $auth_result, undef, 'Self excluded client should not throw error';

my $date_until = Date::Utility->new->plus_time_interval('2d')->date_yyyymmdd;
lives_ok {
    $client->clr_status('disabled');
    $client->set_exclusion->timeout_until(0);
    $client->set_exclusion->exclude_until($date_until);
    $client->save;
}
'Enable client and exclude him until tomorrow';
lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) } 'Should return result of check';
is $auth_result, undef, 'Self excluded client should not throw error';

done_testing();
