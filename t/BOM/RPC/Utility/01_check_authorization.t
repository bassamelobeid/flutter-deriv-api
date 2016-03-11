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
    } 'Initial accounts';
};

my $module = Test::MockModule->new('BOM::Platform::Context::Request');
$module->mock('_build_language', sub { 'RU' });

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization() }
         'Should return result of check';

is_deeply $auth_result->{error},
          {
              message_to_client => 'Пожалуйста, войдите в систему.',
              code              => 'AuthorizationRequired',
          },
          'It should return error: AuthorizationRequired';

lives_ok {
    $client->set_status( 'disabled', 'test', 'test' );
    $client->save;
} 'Disable client';

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) }
         'Should return result of check';

is_deeply   $auth_result->{error},
            {
                code => 'DisabledClient',
                message_to_client => 'Данный счёт недоступен.',
            },
            'It should return error: DisabledClient';

my $date_until = Date::Utility->new->plus_time_interval('1d')->date_yyyymmdd;
lives_ok {
    $client->clr_status('disabled');
    $client->set_exclusion->exclude_until( $date_until );
    $client->save;
} 'Enable client and exclude him until tomorrow';

lives_ok { $auth_result = BOM::RPC::v3::Utility::check_authorization($client) }
         'Should return result of check';

is  $auth_result->{error}->{code},
    'ClientSelfExclusion',
    'It should return error: ClientSelfExclusion';

ok  $auth_result->{error}->{message_to_client} =~ /$date_until/,
    'It should return date until excluded';

done_testing();