use Test::Most 0.22 (tests => 8);
use Test::NoWarnings;
use Sys::Hostname;

use BOM::Platform::Runtime::LandingCompany;
use BOM::Platform::Runtime::LandingCompany::Registry;

my $registry;
lives_ok {
    $registry = BOM::Platform::Runtime::LandingCompany::Registry->new();
}
'Initialized Registry';

my $cr_lc = $registry->get('costarica');
ok $cr_lc, 'Got CR';
is $cr_lc->name, 'Binary (C.R.) S.A.', 'Got the right name';

my $cr_lc2 = $registry->get('Binary (C.R.) S.A.');
ok $cr_lc2, 'Got CR';
is $cr_lc2->short, 'costarica', 'Got the right short code';

is $cr_lc, $cr_lc2, 'We get the same thing, we are sane';

is_deeply([sort $registry->all_currencies],[qw(AUD EUR GBP JPY USD)], 'Can get all currencies');
