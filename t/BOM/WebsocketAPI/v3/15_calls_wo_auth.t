use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test;
use BOM::Platform::Runtime;

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
SKIP: {
    skip 'No landing company tests during transition; check with Kaveh', 12;
    $t = $t->send_ok({json => {landing_company => 'de'}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{landing_company};
    is $res->{landing_company}->{name}, 'Germany';
    is $res->{landing_company}->{financial_company}->{shortcode}, 'maltainvest';
    ok not $res->{landing_company}->{gaming_company};
    test_schema('landing_company', $res);

    $t = $t->send_ok({json => {landing_company => 'im'}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{landing_company};
    is $res->{landing_company}->{name}, 'Isle of Man';
    is $res->{landing_company}->{financial_company}->{shortcode}, 'iom';
    is $res->{landing_company}->{gaming_company}->{shortcode},    'iom';
    test_schema('landing_company', $res);

    $t = $t->send_ok({json => {landing_company => 'XX'}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error};
    is $res->{error}->{code}, 'UnknownLandingCompany';
}

## residence_list
$t = $t->send_ok({json => {residence_list => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{residence_list};
is_deeply $res->{residence_list}->[0],
    {
    value     => 'af',
    text      => 'Afghanistan',
    phone_idd => '93'
    };
test_schema('residence_list', $res);

## states_list
$t = $t->send_ok({json => {states_list => 'MY'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{states_list};
is_deeply $res->{states_list}->[0],
    {
    value => '01',
    text  => 'Johor'
    };
test_schema('states_list', $res);

## website_status
$t = $t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{website_status}->{terms_conditions_version}, BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;

$t->finish_ok;

done_testing();
