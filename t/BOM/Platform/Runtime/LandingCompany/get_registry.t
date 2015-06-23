use Test::Most 0.22 (tests => 8);
use Test::NoWarnings;
use Sys::Hostname;

use BOM::Platform::Runtime::LandingCompany;
use BOM::Platform::Runtime::LandingCompany::Registry;

my $registry;
lives_ok {
    $registry = BOM::Platform::Runtime::LandingCompany::Registry->new();
    $registry->keys;
}
'Initialized Registry';

my $cr_lc = $registry->get('costarica');
ok $cr_lc, 'Got CR';
is $cr_lc->name, 'Binary (C.R.) S.A.', 'Got the right name';

my $cr_lc2 = $registry->get('Binary (C.R.) S.A.');
ok $cr_lc2, 'Got CR';
is $cr_lc2->short, 'costarica', 'Got the right short code';

is $cr_lc, $cr_lc2, 'We get the same thing, we are sane';

throws_ok { $registry->get_landing_company(nama => 'Binary (U.K.) Ltd.'); } qr/Unable to search landing company by nama/,
    'dies if no company name or short specified';

##Test Choose LCs
##Test Initialize LCs
