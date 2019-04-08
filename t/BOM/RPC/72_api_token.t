use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use TestHelper qw/create_test_user/;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::Client;

use BOM::User;
use BOM::User::Client;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::AccessToken;
use Email::Stuffer::TestLinks;

# cleanup
BOM::Database::Model::AccessToken->new->dbic->dbh->do("
    DELETE FROM $_
") foreach ('auth.access_token');

my $client = create_test_user();

my $res = BOM::RPC::v3::Accounts::api_token({
    client => $client,
    args   => {},
});
is_deeply($res, {tokens => []}, 'empty token list');

$res = BOM::RPC::v3::Accounts::api_token({
        client => $client,
        args   => {
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
        client => $client,
        args   => {
            delete_token => $test_token->{token},
        },
    });
ok $res->{delete_token};
is_deeply($res->{tokens}, [], 'empty');

## re-create
$res = BOM::RPC::v3::Accounts::api_token({
    client => $client,
    args   => {new_token => '1'},
});
ok $res->{error}->{message_to_client} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';

$res = BOM::RPC::v3::Accounts::api_token({
    client => $client,
    args   => {new_token => '1' x 33},
});
ok $res->{error}->{message_to_client} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';

## we default to all scopes for backwards
# $res = BOM::RPC::v3::Accounts::api_token({
#     client => $client,
#     args           => {new_token => 'Test'},
# });
# ok $res->{error}->{message_to_client} =~ /new_token_scopes/, 'new_token_scopes is required';

$res = BOM::RPC::v3::Accounts::api_token({
        client => $client,
        args   => {
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

## check for valid ip
$res = BOM::RPC::v3::Accounts::api_token({
        client => $client,
        args   => {
            new_token                 => 'Test1',
            new_token_scopes          => ['read', 'trade'],
            valid_for_current_ip_only => 1,
        },
        client_ip => '1.1.1.1',
    });
is scalar(@{$res->{tokens}}), 2, '2nd token created';
$test_token = $res->{tokens}->[1]->{token};

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
my $params = {
    language   => 'EN',
    token      => $test_token,
    token_type => 'api_token',
    client_ip  => '1.1.1.1'
};
$c->call_ok('authorize', $params)->has_no_error;

$params->{client_ip} = '1.2.1.1';
$c->call_ok('authorize', $params)
    ->has_error->error_message_is('Token is not valid for current ip address.', 'check invalid token as ip is different from registered one');

done_testing();
