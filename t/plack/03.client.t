use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(decode_json request request_xml);

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

subtest 'Handle invalid XML' => sub {
    my $boggus_xml_content = '<deposit account_identifier="email=stuff%40domain.com&country=BR"/>';
    my $buggy_xml_content  = '<deposit account_identifier="<!-- account_identifier -->"/>';

    my $req = request_xml('POST', '/transaction/payment/doughflow/deposit', $boggus_xml_content);

    is $req->code,      422,                      'Expected 422 for XML message with &';
    like $req->content, qr/Unprocessable entity/, 'Expected Unprocessable entity as message';

    $req = request_xml('POST', '/transaction/payment/doughflow/deposit', $buggy_xml_content);

    is $req->code,      422,                      'Expected 422 for XML message with <!-- -->';
    like $req->content, qr/Unprocessable entity/, 'Expected Unprocessable entity as message';
};

done_testing();
