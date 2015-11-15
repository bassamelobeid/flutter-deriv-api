use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $t = build_mojo_test();

# landing_company_details
$t = $t->send_ok({json => {paymentagent_list => 'id'}})->message_ok;
my $res = decode_json($t->message->[1]);
diag Dumper(\$res);
test_schema('paymentagent_list', $res);

$t->finish_ok;

done_testing();
