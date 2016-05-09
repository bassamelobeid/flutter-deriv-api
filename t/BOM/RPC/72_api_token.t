use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use TestHelper qw/create_test_user/;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::System::Password;

use BOM::RPC::v3::Accounts;
use BOM::Database::Model::AccessToken;

# cleanup
BOM::Database::Model::AccessToken->new->dbh->do("
    DELETE FROM $_
") foreach ('auth.access_token');

my $test_loginid = create_test_user();

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
# need to mock it as to access api token we need token beforehand
$mock_utility->mock('get_token_details', sub { return {loginid => $test_loginid} });

my $res = BOM::RPC::v3::Accounts::api_token({
    client_loginid => $test_loginid,
    args           => {},
});
is_deeply($res, {tokens => []}, 'empty token list');

$res = BOM::RPC::v3::Accounts::api_token({
        client_loginid => $test_loginid,
        args           => {
            new_token        => 'Test Token',
            new_token_scopes => ['read'],
        },
    });
ok $res->{new_token};
is scalar(@{$res->{tokens}}), 1, '1 token created';
my $test_token = $res->{tokens}->[0];
is $test_token->{display_name}, 'Test Token';

# delete token
$res = BOM::RPC::v3::Accounts::api_token({
        client_loginid => $test_loginid,
        args           => {
            delete_token => $test_token->{token},
        },
    });
ok $res->{delete_token};
is_deeply($res->{tokens}, [], 'empty');

## re-create
$res = BOM::RPC::v3::Accounts::api_token({
    client_loginid => $test_loginid,
    args           => {new_token => '1'},
});
ok $res->{error}->{message_to_client} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';

$res = BOM::RPC::v3::Accounts::api_token({
    client_loginid => $test_loginid,
    args           => {new_token => '1' x 33},
});
ok $res->{error}->{message_to_client} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';

## we default to all scopes for backwards
# $res = BOM::RPC::v3::Accounts::api_token({
#     client_loginid => $test_loginid,
#     args           => {new_token => 'Test'},
# });
# ok $res->{error}->{message_to_client} =~ /new_token_scopes/, 'new_token_scopes is required';

$res = BOM::RPC::v3::Accounts::api_token({
        client_loginid => $test_loginid,
        args           => {
            new_token        => 'Test',
            new_token_scopes => ['read', 'trade']
        },
    });
is scalar(@{$res->{tokens}}), 1, '1 token created';
$test_token = $res->{tokens}->[0];
is $test_token->{display_name}, 'Test';
ok !$test_token->{last_used}, 'last_used is null';

## check scopes
my @scopes = BOM::Database::Model::AccessToken->new->get_scopes_by_access_token($test_token->{token});
is_deeply([sort @scopes], ['read', 'trade'], 'right scopes');

done_testing();
