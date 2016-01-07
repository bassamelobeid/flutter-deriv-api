use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Client;
use BOM::Platform::Runtime;

use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;

## TRICKY but works
my $version = 1;
BOM::Platform::Runtime->instance->app_config;
my $mock_class = ref(BOM::Platform::Runtime->instance->app_config->cgi);
(my $fname = $mock_class) =~ s!::!/!g;
$INC{$fname . '.pm'} = 1;
my $mock_t_c_version = Test::MockModule->new($mock_class);
$mock_t_c_version->mock('terms_conditions_version', sub { 'version ' . $version });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $test_loginid = $test_client->loginid;

# my $res = BOM::RPC::v3::Utility::website_status();
# is $res->{terms_conditions_version}, 'version 1', 'version 1';

my $res = BOM::RPC::v3::Cashier::tnc_approval({client_loginid => $test_loginid});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    client_loginid => $test_loginid,
    language       => 'EN'
});
is $res->{client_tnc_status}, 'version 1', 'version 1';

$version = 2;
$res = BOM::RPC::v3::Cashier::tnc_approval({client_loginid => $test_loginid});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    client_loginid => $test_loginid,
    language       => 'EN'
});
is $res->{client_tnc_status}, 'version 2', 'version 2';

done_testing();
