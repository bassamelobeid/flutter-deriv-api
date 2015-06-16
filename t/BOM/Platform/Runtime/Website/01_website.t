use Test::Most 0.22 (tests => 5);
use Test::NoWarnings;
use Test::MockModule;
use File::Basename qw();
use JSON qw(decode_json);

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::Website;
use BOM::Platform::Runtime::Broker;
use BOM::Platform::Runtime::LandingCompany;

my $iom = BOM::Platform::Runtime::LandingCompany->new(
    short   => 'iom',
    name    => 'Binary (IOM) Ltd',
    address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
    fax     => '+44 207 6813557',
    country => 'Isle of Man',
);
isa_ok $iom, 'BOM::Platform::Runtime::LandingCompany';

my $cr = BOM::Platform::Runtime::Broker->new(
    code                   => 'CR',
    server                 => 'localhost',
    landing_company        => $iom,
    transaction_db_cluster => 'CR',
);

isa_ok $cr, 'BOM::Platform::Runtime::Broker';

my $binary = new_ok(
    'BOM::Platform::Runtime::Website',
    [
        name            => 'Binary',
        primary_url     => 'www.binary.com',
        features        => ['affiliates', 'training_videos', 'call_back'],
        broker_codes    => [$cr,],
        localhost       => BOM::Platform::Runtime->instance->hosts->localhost,
        resource_subdir => 'Binary',
    ],
);

is_deeply($binary->broker_codes->[0], $cr, 'Right Broker Object');
