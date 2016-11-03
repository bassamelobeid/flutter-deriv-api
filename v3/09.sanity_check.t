use strict;
use warnings;
use Test::More;
#use Test::NoWarnings; #
use Test::FailWarnings;

use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use utf8;

my $t = build_wsapi_test();

$t = $t->send_ok({json => {ping => '௰'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'SanityCheckFailed';
ok ref($res->{echo_req}) eq 'HASH' && !keys %{$res->{echo_req}};
test_schema('ping', $res);

# undefs are fine for some values
$t = $t->send_ok({json => {ping => {key => undef}}})->message_ok;

$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => '௰',
            new_password    => '௰'
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{code} ne 'SanityCheckFailed', 'Do not check value of password key';

$t = $t->send_ok({
        json => {
            change_password    => 1,
            '௰_old_password' => '௰',
            new_password       => '௰'
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'SanityCheckFailed', 'Should be failed if paswword key consist of non sanity symbols';

$t->finish_ok;

done_testing();
