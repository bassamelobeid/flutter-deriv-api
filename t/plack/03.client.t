use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(decode_json request);

my $loginid = 'CR0011';
my $r       = request('GET', '/client', {client_loginid => $loginid});

my $cli_data = decode_json($r->content);

is($cli_data->{loginid}, $loginid, 'correct client');
my @expected_fields =
    qw( salutation address_state address_postcode last_name date_joined email address_city address_line_1 gender country phone address_line_2 restricted_ip_address loginid first_name);
isnt($cli_data->{$_}, undef, "property $_ is defined") foreach @expected_fields;

## try with bad client_loginid or currency_code
$r = request(
    'GET',
    '/client',
    {
        client_loginid => 'CR0999000',
    });
is($r->code, 401);    # Authorization required

done_testing();
