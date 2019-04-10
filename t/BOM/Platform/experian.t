use strict;
use warnings;

use Test::MockTime qw(set_fixed_time restore_time);
set_fixed_time("939988800");
use Test::Most 'no_plan';
use Test::MockModule;
use BOM::Platform::ProveID;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Config;
use Test::Exception;
use Test::Deep;
use File::Compare qw(compare);
use XML::SemanticDiff;
subtest 'Constructor' => sub {
    subtest 'No Client' => sub {
        throws_ok(sub { BOM::Platform::ProveID->new() }, qr/Missing required arguments: client/, "Constructor dies with no client");
    };
    subtest 'With Client' => sub {
        my $client = create_client();
        my $obj = BOM::Platform::ProveID->new(client => $client);
        isa_ok($obj, "BOM::Platform::ProveID", "Constructor ok with client");
    };
};

subtest 'Request Tags' => sub {
    my $client = create_client("MX");
    $client->residence('gb');

    my $loginid = $client->loginid;

    # Expected generated tags
    my $tags = {
        Two_FA_Header => bless({
                '_prefix'    => 'head',
                '_name'      => 'Signature',
                '_value'     => ['4Tz1BSVm3MQgWCHeRQMn++uL7VpTv+PEI3ari/qfnSI=_939988800_dummy'],
                '_attr'      => {},
                '_signature' => []
            },
            'SOAP::Header'
        ),
        Authentication => '<Authentication><Username>dummy</Username><Password>dummy</Password></Authentication>',
        Person         => '<Person><Name><Forename>bRaD</Forename><Surname>pItT</Surname></Name><DateOfBirth>1978-06-23</DateOfBirth></Person>',
        Address =>
            '<Addresses><Address Current="1"><Premise>Civic Center </Premise><Postcode>232323</Postcode><CountryCode>GBR</CountryCode></Address></Addresses>',
        CountryCode     => '<CountryCode>GBR</CountryCode>',
        Telephones      => '<Telephones><Telephone Type="U"><Number>+112123121</Number></Telephone></Telephones>',
        SearchReference => "<YourReference>PK_" . $loginid . "_939988800</YourReference>",
        SearchOption    => '<SearchOptions><ProductCode>ProveID_KYC</ProductCode></SearchOptions>'
    };

    my $obj = BOM::Platform::ProveID->new(client => $client);

    subtest '2FA Header' => sub {
        cmp_deeply($obj->_2fa_header, $tags->{Two_FA_Header}, "2FA Header ok");
    };
    subtest 'Authentication' => sub {
        is($obj->_build_authentication_tag, $tags->{Authentication}, "Authentication tag ok");
    };
    subtest 'Person' => sub {
        is($obj->_build_person_tag, $tags->{Person}, "Person tag ok");
    };
    subtest 'Address' => sub {
        is($obj->_build_addresses_tag, $tags->{Address}, "Address tag ok");
    };
    subtest 'Country Code' => sub {
        $client->residence('aa');    # Set to invalid Country code
        throws_ok(sub { $obj->_build_country_code_tag }, qr/could not get three letter country code/, "Country code tag fail on invalid residence");

        $client->residence('gb');    # Restore to valid Country code
        is($obj->_build_country_code_tag, $tags->{CountryCode}, "Country code tag ok");
    };
    subtest 'Telephones' => sub {
        is($obj->_build_telephones_tag, $tags->{Telephones}, "Telephones tag ok");
    };
    subtest 'Search Reference' => sub {
        is($obj->_build_search_reference_tag, $tags->{SearchReference}, "Search reference tag ok");
    };
    subtest 'Search Option' => sub {
        is($obj->_build_search_option_tag, $tags->{SearchOption}, "Search option tag ok");
    };
};

subtest 'Response' => sub {

    my $entries = [map { "Experian$_" } qw(Valid InsufficientDOB Deceased OFSI PEP BOE InsufficientUKGC)];
    my $xml_fld = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/";
    my $pdf_fld = "/home/git/regentmarkets/bom-test/data/Experian/PDF/";

    for my $entry (@$entries) {
        subtest $entry => sub {
            my $client  = create_client("MX");
            my $loginid = $client->loginid;
            $client->first_name($entry);
            $client->residence('gb');

            my $xml_file = $xml_fld . $entry . ".xml";
            my $pdf_file = $pdf_fld . $entry . ".pdf";
            ok(BOM::Platform::ProveID->new(client => $client)->get_result, "get result response ok");

            is(XML::SemanticDiff->new()->compare($xml_file, "/db/f_accounts/MX/192com_authentication/xml/" . $loginid . ".ProveID_KYC"),
                0, "xml saved ok");
            is(compare($pdf_file, "/db/f_accounts/MX/192com_authentication/pdf/" . $loginid . ".ProveID_KYC.pdf"), 0, "pdf saved ok");
        };
    }

    subtest 'Not Found' => sub {
        my $client = create_client("MX");

        throws_ok(
            sub { BOM::Platform::ProveID->new(client => $client)->get_result },
            qr/Experian XML Request Failed with ErrorCode: 501, ErrorMessage: No Match Found/,
            "not found fails ok"
        );
    };

    subtest 'Fault' => sub {
        my $client = create_client("MX");
        $client->first_name("ExperianFault");

        throws_ok(
            sub { BOM::Platform::ProveID->new(client => $client)->get_result },
            qr/Encountered SOAP Fault when sending xml request : Test Fault Code : Test Fault String/,
            "fault fails ok"
        );
        }
};

subtest 'Replace Existing Result' => sub {
    my $client  = create_client("MX");
    my $loginid = $client->loginid;
    $client->first_name('ExperianBOE');

    BOM::Platform::ProveID->new(client => $client)->get_result;

    $client->first_name('ExperianValid');

    # Run again to replace existing files
    BOM::Platform::ProveID->new(client => $client)->get_result;

    my $saved_xml = "/db/f_accounts/MX/192com_authentication/xml/" . $loginid . ".ProveID_KYC";
    my $saved_pdf = "/db/f_accounts/MX/192com_authentication/pdf/" . $loginid . ".ProveID_KYC.pdf";

    my $expected_xml = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianValid.xml";
    my $expected_pdf = "/home/git/regentmarkets/bom-test/data/Experian/PDF/ExperianValid.pdf";
    is(XML::SemanticDiff->new()->compare($saved_xml, $expected_xml), 0, "xml replaced ok");
    is(compare($saved_pdf, $expected_pdf), 0, "pdf replaced ok");

    BOM::Platform::ProveID->new(client => $client)->delete_existing_reports;

    is(-e $saved_xml, undef, "Deleted xml ok");
    is(-e $saved_pdf, undef, "Deleted pdf ok");
};

# If run with -uat option (prove experian.t :: -uat), we will run tests against Experian's actual UAT server
if ($ARGV[0] and $ARGV[0] eq '-uat') {
    restore_time();
    subtest 'Authentication' => sub {
        my $client = create_client("MX");

        # Test client details from Experian UAT
        $client->residence("gb");
        $client->first_name('Sirath');
        $client->last_name('Niver');
        $client->date_of_birth("1994-07-01");
        $client->address_1("345");
        $client->postcode("LA16 7DG");

        my $username    = BOM::Config::third_party()->{proveid}->{uat}->{username};
        my $password    = BOM::Config::third_party()->{proveid}->{uat}->{password};
        my $private_key = BOM::Config::third_party()->{proveid}->{uat}->{private_key};
        my $public_key  = BOM::Config::third_party()->{proveid}->{uat}->{public_key};

        my $mock = Test::MockModule->new('BOM::Platform::ProveID');

        my $uat_uri   = "https://uat.proveid.experian.com";
        my $uat_proxy = "https://xml.uat.proveid.experian.com/IDSearch.cfc";

        # PDF downloads don't work with UAT
        $mock->mock(
            get_pdf_result   => sub { return 1; },
            _save_pdf_result => sub { return 1; });

        subtest 'Valid Auth' => sub {
            ok(
                BOM::Platform::ProveID->new(
                    client      => $client,
                    api_uri     => $uat_uri,
                    api_proxy   => $uat_proxy,
                    username    => $username,
                    password    => $password,
                    private_key => $private_key,
                    public_key  => $public_key

                    )->get_result,
                "Auth ok"
            );
        };

        subtest 'Invalid Username/Password' => sub {
            throws_ok(
                sub {
                    BOM::Platform::ProveID->new(
                        client      => $client,
                        api_uri     => $uat_uri,
                        api_proxy   => $uat_proxy,
                        username    => "WrongUsername",
                        password    => $password,
                        private_key => $public_key,
                        public_key  => $private_key
                    )->get_result;
                },
                qr/Experian XML Request Failed with ErrorCode: 001, ErrorMessage: Authentication Error: Bad Username or Password/,
                "Invalid Username fails ok"
            );
        };

        subtest 'Invalid 2FA header' => sub {
            throws_ok(
                sub {
                    BOM::Platform::ProveID->new(
                        client      => $client,
                        api_uri     => $uat_uri,
                        api_proxy   => $uat_proxy,
                        username    => $username,
                        password    => $password,
                        private_key => $public_key,
                        private_key => "WrongPrivateKey"
                    )->get_result;
                },
                qr/Experian XML Request Failed with ErrorCode: 000, ErrorMessage: Authentication Error/,
                "Invalid 2FA header fails ok"
            );
        };
    };
}

1;
