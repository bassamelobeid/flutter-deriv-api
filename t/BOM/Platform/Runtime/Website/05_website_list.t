use Test::Most 0.22 (tests => 7);
use Test::NoWarnings;
use Test::MockModule;
use Sys::Hostname;
use JSON qw(decode_json);
use YAML::XS;

use BOM::Platform::Runtime::Website::List;
use BOM::Platform::Runtime;

my $website_list;
lives_ok {
    $website_list = BOM::Platform::Runtime::Website::List->new(
        definitions  => YAML::XS::LoadFile('/home/git/regentmarkets/bom/config/files/websites.yml'),
        broker_codes => BOM::Platform::Runtime->instance->broker_codes,
        localhost    => BOM::Platform::Runtime->instance->hosts->localhost,
    );
}
'Initialized';

subtest 'defaults' => sub {
    is $website_list->default_website->name, 'Binary', 'Correct default website';
};

subtest 'get' => sub {
    my $website = $website_list->get('Binary');
    is $website->broker_for_new_account()->code, 'CR',   'New Broker Code - Binary';
    is $website->broker_for_new_virtual()->code, 'VRTC', 'New Virtual Broker Code - Binary';

};

subtest 'get_by_broker_code' => sub {
    my $website = $website_list->get_by_broker_code("CR");
    ok $website, 'Got some website for CR';
    is $website->name, 'Binary', 'Binary is for CR';

    $website = $website_list->get_by_broker_code("MLT");
    ok $website, 'Got some website for MLT';
    is $website->name, 'Binary', 'Binary is for MLT';

    $website = $website_list->get_by_broker_code("MX");
    ok $website, 'Got some website for MX';
    is $website->name, 'Binary', 'Binary is for MX';

    $website = $website_list->get_by_broker_code("VRTC");
    ok $website, 'Got some website for VRTC';
    is $website->name, 'Binary', 'Binary is for VRTC';

    $website = $website_list->get_by_broker_code("OOO");
    ok $website, 'Got some website for OOO(unknown)';
    is $website->name, 'Binary', 'Binary is for OOO(unknown)';
};

cmp_deeply [sort map { $_->name } $website_list->all],
    [
    'BackOffice', 'Binary',     'Binaryqa01', 'Binaryqa02', 'Binaryqa03', 'Binaryqa04', 'Binaryqa05', 'Binaryqa06',
    'Binaryqa07', 'Binaryqa08', 'Binaryqa09', 'Binaryqa10', 'Binaryqa11', 'Binaryqa12', 'Devbin'
    ],
    "A list of all known websites";

lives_ok {
    BOM::Platform::Runtime->instance->website_list;
}
'lives through runtime build';
