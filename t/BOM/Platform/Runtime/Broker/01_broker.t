use Test::Most 0.22 (tests => 10);
use Test::NoWarnings;

use BOM::Platform::Runtime::Broker;
use BOM::Platform::Runtime::LandingCompany;

my $iom = BOM::Platform::Runtime::LandingCompany->new(
    short   => 'iom',
    name    => 'Binary (IOM) Ltd',
    address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
    fax     => '+44 207 6813557',
    country => 'Isle of Man',
);

my $cr = BOM::Platform::Runtime::Broker->new(
    code                   => 'CR',
    server                 => 'localhost',
    landing_company        => $iom,
    transaction_db_cluster => 'CR',
);
isa_ok $cr, 'BOM::Platform::Runtime::Broker';
is $cr->code,   "CR",        "Broker code is correct";
is $cr->server, "localhost", "Dealing locally";
ok !$cr->is_virtual, "CR is not virtual";
throws_ok { $cr->code('VRTC'); } qr/Cannot assign a value to a read-only accessor/, 'Cannot set broker code';

my $vrtc = BOM::Platform::Runtime::Broker->new(
    code                   => 'VRTC',
    server                 => 'vrt.example.com',
    landing_company        => $iom,
    transaction_db_cluster => 'VRTC',
);
my $test = BOM::Platform::Runtime::Broker->new(
    code                   => 'TEST',
    is_virtual             => 1,
    landing_company        => $iom,
    transaction_db_cluster => 'TT',
);

ok $vrtc->is_virtual, "VRTC is virtual";
is $vrtc->server,     "vrt.example.com", "Dealing VRTC on vrt.example.com";
ok $test->is_virtual, "TEST is virtual";
is $test->server,     "localhost", "Dealing TEST locally";
