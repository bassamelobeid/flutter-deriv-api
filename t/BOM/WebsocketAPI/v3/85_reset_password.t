use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $t = build_mojo_test();

$t = $t->send_ok({json => {reset_password => 1}})->message_ok;
my $reset_password = decode_json($t->message->[1]);
is($reset_password->{error}->{code}, 'InputValidationFailed');
test_schema('reset_password', $reset_password);

t->finish_ok;

done_testing();
