use strict;
use warnings;
use JSON;
use Test::More;
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;

# pass blank app_id
my $t = build_wsapi_test({
    language => 'EN',
    app_id   => ''
});

# all calls will return error
$t = $t->send_ok({json => {ping => 1}})->message_ok;

my $res = decode_json($t->message->[1]);
is($res->{error}->{code}, 'AccessForbidden', 'Missing app id, correct error code');

# even authenticated calls requested without token will get same error
$t = $t->send_ok({json => {balance => 1}})->message_ok;
is($res->{error}->{code}, 'AccessForbidden', 'Missing app id, correct error code');

$t->finish_ok;

done_testing();
