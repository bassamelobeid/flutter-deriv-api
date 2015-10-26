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
test_schema('landing_company_details', $res);

$t = $t->send_ok({json => {landing_company_details => 'iom'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{landing_company_details};
is $res->{landing_company_details}->{country}, 'Isle of Man';
test_schema('landing_company_details', $res);

$t = $t->send_ok({json => {landing_company_details => 'unknown_blabla'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error};
is $res->{error}->{code}, 'UnknownLandingCompany';

# landing_company
$t = $t->send_ok({json => {landing_company => 'de'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{landing_company};
is $res->{landing_company}->{name}, 'Germany';
is $res->{landing_company}->{financial_company}->{shortcode}, 'maltainvest';
ok not $res->{landing_company}->{gaming_company};

$t = $t->send_ok({json => {landing_company => 'im'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{landing_company};
is $res->{landing_company}->{name}, 'Isle of Man';
is $res->{landing_company}->{financial_company}->{shortcode}, 'iom';
is $res->{landing_company}->{gaming_company}->{shortcode}, 'iom';

$t = $t->send_ok({json => {landing_company => 'blabla'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error};
is $res->{error}->{code}, 'UnknownLandingCompany';

$t->finish_ok;

done_testing();
