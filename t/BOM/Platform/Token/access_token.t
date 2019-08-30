use strict;
use warnings;
use Test::More;
use BOM::Platform::Token::API;
use BOM::Database::Model::AccessToken;

# mockup for BOM::Test::Data::Utility::UnitTestRedis
# since bom-postgres do not rely on bom-market
BEGIN {
    $INC{'BOM/Market/Underlying.pm'} = 1;
    $INC{'BOM/Market/AggTicks.pm'}   = 1;
}

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);

#cleanup
cleanup_redis_tokens();
BOM::Database::Model::AccessToken->new->dbic->dbh->do("DELETE FROM auth.access_token");
my $test_loginid = 'CR10002';
my $m = BOM::Platform::Token::API->new;

ok not $m->is_name_taken($test_loginid, 'Test Token');
my $token = $m->create_token($test_loginid, 'Test Token', ['read', 'admin', 'payments']);
is length($token), 15;
ok $m->is_name_taken($test_loginid, 'Test Token'), 'name is taken after create';
my @scopes = $m->get_scopes_by_access_token($token);
is_deeply([sort @scopes], ['admin', 'payments', 'read'], 'token has right scope');

my $client_loginid = $m->get_token_details($token, 1)->{loginid};
is $client_loginid, $test_loginid;

my $tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
is $tokens->[0]->{token},        $token;
is $tokens->[0]->{display_name}, 'Test Token';
is_deeply [sort @{$tokens->[0]->{scopes}}], ['admin', 'payments', 'read'];
ok $tokens->[0]->{last_used} =~ /^[\d\-]{10}\s+[\d\:]{8}$/;    # update on get_token_details
my $token_cnt = $m->get_token_count_by_loginid($test_loginid);
is $token_cnt, 1;

my $ok = $m->remove_by_token($token, $test_loginid);
ok $ok;

$client_loginid = $m->get_token_details($token)->{loginid};
is $client_loginid, undef;                                     # it should be undef since removed

$m->create_token($test_loginid, 'Test Token');
$tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
ok $m->remove_by_loginid($test_loginid), 'remove ok';
$tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 0, 'all removed';

### test scope
$token = $m->create_token($test_loginid, 'Test Token X', ['read', 'admin']);
@scopes = $m->get_scopes_by_access_token($token);
is_deeply([sort @scopes], ['admin', 'read'], 'scope is correct');

### test ip
ok $m->remove_by_loginid($test_loginid), 'remove ok';
$token = $m->create_token($test_loginid, 'Test Token X', ['read', 'admin'], '127.0.0.1');
$tokens = $m->get_tokens_by_loginid($test_loginid);
is $tokens->[0]->{valid_for_ip}, '127.0.0.1';

done_testing();
