use strict;
use warnings;
use Test::More;
use BOM::Database::Model::AccessToken;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $m = BOM::Database::Model::AccessToken->new;
my $test_loginid = 'CR10002';

my $token = $m->create_token($test_loginid, 'Test Token');
is length($token), 12;

my $client_loginid = $m->get_loginid_by_token($token);
is $client_loginid, $test_loginid;

my $tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
is $tokens->[0]->{token}, $token;
is $tokens->[0]->{client_loginid}, $test_loginid;
is $tokens->[0]->{display_name}, 'Test Token';
is $tokens->[0]->{last_used}, undef;

my $unused_token = $m->generate_unused_token();
ok( $unused_token ne $token );

$m->update_last_used_by_token($token);
$tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
is $tokens->[0]->{token}, $token;
is $tokens->[0]->{client_loginid}, $test_loginid;
is $tokens->[0]->{display_name}, 'Test Token';
ok($tokens->[0]->{last_used});

my $new_token = $m->revoke_token($token);
$client_loginid = $m->get_loginid_by_token($token);
is $client_loginid, undef;
$client_loginid = $m->get_loginid_by_token($new_token);
is $client_loginid, $test_loginid;

my $ok = $m->remove_by_token($new_token);
ok $ok;

done_testing();