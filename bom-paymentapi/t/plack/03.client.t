use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(decode_json request request_xml request_json request_with_content_type);
use BOM::Database::ClientDB;
use BOM::User;

my $loginid = 'CR0011';

my $client_db = BOM::Database::ClientDB->new({client_loginid => $loginid});
my $user      = BOM::User->create(
    email    => 'unit_test@deriv.com',
    password => 'Abcd1234'
);
$user->add_loginid($loginid);

my $r = request('GET', '/client', {client_loginid => $loginid});

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

subtest 'Handle valid XML' => sub {
    my $valid_xml_content =
        '<deposit amount="50" bonus="0" client_loginid="CR0011" created_by="INTERNET" currency_code="USD" fee="0" ip_address="127.0.01" payment_processor="Skrill" payment_method="Skrill" promo_id="" trace_id="00112234" transaction_id="0011223345" account_identifier="***" card_exp="" payment_type="EWallet" udef1="ES" udef2="binary" udef3="" udef4="" udef5="" />';

    my $req = request_xml('POST', '/transaction/payment/doughflow/deposit', $valid_xml_content);

    is $req->code, 201, 'Expected 201 for valid XML message';
};

subtest 'Handle invalid XML' => sub {
    my $boggus_xml_content = '<deposit account_identifier="email=stuff%40domain.com&country=BR"/>';
    my $buggy_xml_content  = '<deposit account_identifier="<!-- account_identifier -->"/>';

    my $req = request_xml('POST', '/transaction/payment/doughflow/deposit', $boggus_xml_content);

    is $req->code, 422, 'Expected 422 for XML message with &';
    like $req->content, qr/Unprocessable entity/, 'Expected Unprocessable entity as message';

    $req = request_xml('POST', '/transaction/payment/doughflow/deposit', $buggy_xml_content);

    is $req->code, 422, 'Expected 422 for XML message with <!-- -->';
    like $req->content, qr/Unprocessable entity/, 'Expected Unprocessable entity as message';
};

subtest 'Handle valid JSON' => sub {
    my $valid_json_content =
        '{"amount":"5","bonus":"0","client_loginid":"CR0011","created_by":"INTERNET","currency_code":"USD","fee":"0","ip_address":"127.0.0.1","payment_processor":"Skrill","payment_method":"Skrill","promo_id":"","trace_id":"00112233","transaction_id":"0011223344","account_identifiers":"***","payment_type":"EWallet","udef1":"EN","udef2":"binary","udef3":"","udef4":"","udef5":""}';

    my $req = request_json('POST', '/transaction/payment/doughflow/deposit', $valid_json_content);

    is $req->code, 201, 'Expected 201 for valid JSON message';
};

subtest 'Handle invalid JSON' => sub {
    my $invalid_json_content = '{"deposit":{"account_identifier"="email=stuff%40domain.com&country=BR"}}';

    my $req = request_json('POST', '/transaction/payment/doughflow/deposit', $invalid_json_content);

    is $req->code, 422, 'Expected 422 for invalid JSON message';
    like $req->content, qr/Unprocessable entity/, 'Expected Unprocessable entity as message';
};

subtest 'Handle invalid Content Type' => sub {
    my $invalid_content = [
        amount         => "5",
        bonus          => "0",
        client_loginid => "CR0011",
        created_by     => "INTERNET"
    ];

    my $req = request_with_content_type({
        method       => 'POST',
        url          => '/transaction/payment/doughflow/deposit',
        content      => $invalid_content,
        content_type => 'text/x-yaml'
    });

    is $req->code, 415, 'Expected 415 for invalid content type';
    like $req->content, qr/Unsupported Media Type/, 'Expected Unsupported Media Type as message';
};

done_testing();
