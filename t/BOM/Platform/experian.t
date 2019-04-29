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
use Path::Tiny;

my %cache;
my $mock_s3 = Test::MockModule->new('BOM::Platform::S3Client');
$mock_s3->mock(
    'upload',
    sub {
        my ($self, $file_name, $file, $checksum) = @_;
        $cache{$file_name} = path($file)->slurp;
        return Future->done;
    });
$mock_s3->mock('download', sub { my ($self, $file) = @_; return exists $cache{$file} ? Future->done($cache{$file}) : Future->fail("no such file"); });
$mock_s3->mock('head_object', sub { my ($self, $file) = @_; return exists $cache{$file} ? Future->done : Future->fail("no such file") });
$mock_s3->mock('delete', sub { my ($self, $file) = @_; delete $cache{$file}; return Future->done(1) });

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
    my $entries = [map { "Experian$_" } qw(Valid InsufficientDOB Deceased OFSI PEP BOE InsufficientUKGC Blank)];
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
            my $proveid  = BOM::Platform::ProveID->new(client => $client);
            ok(my $result = $proveid->get_result, "get result response ok");
            my $tmp_xml_file = Path::Tiny::tempfile;
            $tmp_xml_file->spew($result);
            my $tmp_pdf_file = Path::Tiny::tempfile;
            $tmp_pdf_file->spew($proveid->s3client->download($proveid->_pdf_file_name)->get);
            $tmp_pdf_file->copy("/tmp/tmp_$entry.pdf");
            is(XML::SemanticDiff->new()->compare($xml_file, "$tmp_xml_file"), 0, "xml saved ok");
            is(compare($tmp_pdf_file, $pdf_file), 0, "pdf saved ok");
            $proveid->delete_existing_reports;
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
            qr/Encountered SOAP Fault when sending XML request : Test Fault Code : Test Fault String/,
            "fault fails ok"
        );
        }
};

subtest 'Replace Existing Result' => sub {
    my $client  = create_client("MX");
    my $loginid = $client->loginid;
    $client->first_name('ExperianBOE');

    my $proveid = BOM::Platform::ProveID->new(client => $client);
    my $result = $proveid->get_result;
    $client->first_name('ExperianValid');

    # Run again to replace existing files
    $result = BOM::Platform::ProveID->new(client => $client)->get_result;
    my $tmp_file = Path::Tiny::tempfile;

    my $expected_xml = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianValid.xml";
    $tmp_file->spew($result);
    is(XML::SemanticDiff->new()->compare("$tmp_file", $expected_xml), 0, "xml replaced ok");

    $proveid = BOM::Platform::ProveID->new(client => $client);
    $proveid->delete_existing_reports;
    # test has_saved_xml etc
    ok(!$proveid->has_saved_xml, 'saved xml deleted');
};

subtest 'Other ProveID Methods' => sub {
    my $client  = create_client("MX");
    my $loginid = $client->loginid;
    $client->first_name('ExperianDeceased');

    my $proveid = BOM::Platform::ProveID->new(client => $client);

    ok(!$proveid->has_saved_xml, 'no saved xml yet');
    ok(!$proveid->xml_result,    'no xml result yet');
    ok(!$proveid->has_saved_pdf, 'no saved pdf yet');
    is($proveid->_xml_file_name, "$loginid.ProveID_KYC.xml", 'test xml file name');
    is($proveid->_pdf_file_name, "$loginid.ProveID_KYC.pdf", 'test pdf file name');
    ok($proveid->xml_url, "there is xml url");
    ok($proveid->pdf_url, "there is pdf url");

    my $result = $proveid->get_result;
    ok($proveid->has_saved_xml, 'has saved xml now');
    ok(my $xml_result = $proveid->xml_result,    'has xml result now');
    ok(my $pdf        = $proveid->has_saved_pdf, 'has saved pdf now');
    $proveid = BOM::Platform::ProveID->new(client => $client);    # create a new object to test stored file
    is($proveid->xml_result, $xml_result, 'xml result is ok');

    # test back-compatible: read xml from s3 first
    my $xml_folder = path("/tmp/xml");
    $xml_folder->mkpath;
    my $xml_file = $xml_folder->child($proveid->_file_name);
    $xml_file->spew("hello world");
    isnt(
        BOM::Platform::ProveID->new(
            client => $client,
            folder => '/tmp'
            )->xml_result,
        "hello world",
        "xml result will be fetched from s3 first"
    );
    delete $cache{$proveid->_xml_file_name};
    is(
        BOM::Platform::ProveID->new(
            client => $client,
            folder => '/tmp'
            )->xml_result,
        "hello world",
        "xml result will then be fetched from local dir"
    );

    BOM::Platform::ProveID->new(
        client => $client,
        folder => '/tmp'
    )->get_result;
    ok(!$xml_file->exists,                       'local file dropped when we re-fetch the result');
    ok(exists($cache{$proveid->_xml_file_name}), 'xml file stored on s3');
    $proveid->delete_existing_reports;
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
