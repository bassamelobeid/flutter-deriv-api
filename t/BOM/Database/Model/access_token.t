use strict;
use warnings;
use Test::More;
use BOM::Database::Model::AccessToken;

# mockup for BOM::Test::Data::Utility::UnitTestRedis
# since bom-postgres do not rely on bom-market
BEGIN {
    $INC{'BOM/Market/Underlying.pm'} = 1;
    $INC{'BOM/Market/AggTicks.pm'} = 1;
}

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m = BOM::Database::Model::AccessToken->new;
my $test_loginid = 'CR10002';

my $token = $m->create_token($test_loginid, 'Test Token');
is length($token), 15;

my $client_loginid = $m->get_loginid_by_token($token);
is $client_loginid, $test_loginid;
$client_loginid = $m->get_loginid_by_token($token); # again with redis
is $client_loginid, $test_loginid;

my $tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
is $tokens->[0]->{token}, $token;
is $tokens->[0]->{client_loginid}, $test_loginid;
is $tokens->[0]->{display_name}, 'Test Token';
is $tokens->[0]->{last_used}, undef;

$m->update_last_used_by_token($token);
$tokens = $m->get_tokens_by_loginid($test_loginid);
is scalar @$tokens, 1;
is $tokens->[0]->{token}, $token;
is $tokens->[0]->{client_loginid}, $test_loginid;
is $tokens->[0]->{display_name}, 'Test Token';
ok($tokens->[0]->{last_used});

my $ok = $m->remove_by_token($token);
ok $ok;

$client_loginid = $m->get_loginid_by_token($token);
is $client_loginid, undef; # it should be undef since removed

done_testing();