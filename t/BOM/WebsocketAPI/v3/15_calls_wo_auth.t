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
$t = $t->send_ok({json => {landing_company_details => 'costarica'}})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{landing_company_details};
is $res->{landing_company_details}->{country}, 'Costa Rica';

$t = $t->send_ok({json => {landing_company_details => 'iom'}})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{landing_company_details};
is $res->{landing_company_details}->{country}, 'Isle of Man';

$t = $t->send_ok({json => {landing_company_details => 'unknown_blabla'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error};
is $res->{error}->{code}, 'UnknownLandingCompany';

$t->finish_ok;

done_testing();
