use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Client;
use BOM::Platform::Runtime;
use BOM::Database::Model::AccessToken;

use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;

## TRICKY but works
my $version    = 1;
my $mock_class = ref(BOM::Platform::Runtime->instance->app_config->cgi);
(my $fname = $mock_class) =~ s!::!/!g;
$INC{$fname . '.pm'} = 1;
my $mock_t_c_version = Test::MockModule->new($mock_class);
$mock_t_c_version->mock('terms_conditions_version', sub { 'version ' . $version });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $test_loginid = $test_client->loginid;

my $res = BOM::RPC::v3::Utility::website_status(BOM::Platform::Runtime->instance->app_config);
is $res->{terms_conditions_version}, 'version 1', 'version 1';

# cleanup
BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid);

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
# need to mock it as to access api token we need token beforehand
$mock_utility->mock('token_to_loginid', sub { return $test_loginid });

# create new api token
$res = BOM::RPC::v3::Accounts::api_token({
        token => 'Abc123',
        args  => {
            api_token => 1,
            new_token => 'Sample1'
        }});
is scalar(@{$res->{tokens}}), 1, "token created succesfully";
my $token = $res->{tokens}->[0]->{token};

$mock_utility->unmock('token_to_loginid');

$res = BOM::RPC::v3::Accounts::tnc_approval({token => $token});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    token    => $token,
    language => 'EN'
});
is $res->{client_tnc_status}, 'version 1', 'version 1';

# switch to version 2
$version = 2;

$res = BOM::RPC::v3::Utility::website_status(BOM::Platform::Runtime->instance->app_config);
is $res->{terms_conditions_version}, 'version 2', 'version 2';

$res = BOM::RPC::v3::Accounts::tnc_approval({token => $token});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    token    => $token,
    language => 'EN'
});
is $res->{client_tnc_status}, 'version 2', 'version 2';

$res = BOM::RPC::v3::Accounts::api_token({
        token => $token,
        args  => {
            api_token    => 1,
            delete_token => $token
        }});
is scalar(@{$res->{tokens}}), 0, "token deleted successfully";

done_testing();
