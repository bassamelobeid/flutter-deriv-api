use Test::Most 0.22 (tests => 6);
use Test::NoWarnings;
use BOM::Platform::Runtime;

my $lc_registry = BOM::Platform::Runtime->instance->landing_companies;
my $cr          = $lc_registry->get('costarica');
my $cr2         = $lc_registry->get('Binary (C.R.) S.A.');
isa_ok $cr, 'BOM::Platform::Runtime::LandingCompany';
is $cr, $cr2, 'Got the same object by short and by name';
is $cr->name, 'Binary (C.R.) S.A.', "Correct name for landing company";

subtest 'is_currency_legal' => sub {
    subtest 'costarica' => sub {
        my $broker = $lc_registry->get('costarica');
        ok $broker->is_currency_legal('USD'), 'USD';
        ok $broker->is_currency_legal('GBP'), 'GBP';
        ok $broker->is_currency_legal('AUD'), 'AUD';
        ok $broker->is_currency_legal('EUR'), 'EUR';
        ok !$broker->is_currency_legal('ZWD'), 'ZWD';
    };

    subtest 'malta' => sub {
        my $broker = $lc_registry->get('malta');
        ok $broker->is_currency_legal('USD'), 'USD';
        ok $broker->is_currency_legal('GBP'), 'GBP';
        ok $broker->is_currency_legal('EUR'), 'EUR';
        ok !$broker->is_currency_legal('AUD'), 'AUD';
        ok !$broker->is_currency_legal('ZWD'), 'ZWD';
    };

    subtest 'iom' => sub {
        my $broker = $lc_registry->get('iom');
        ok $broker->is_currency_legal('USD'), 'USD';
        ok $broker->is_currency_legal('GBP'), 'GBP';
        ok !$broker->is_currency_legal('EUR'), 'EUR';
        ok !$broker->is_currency_legal('AUD'), 'AUD';
        ok !$broker->is_currency_legal('ZWD'), 'ZWD';
    };

    subtest 'jp' => sub {
        my $broker = $lc_registry->get('japan');
        ok $broker->is_currency_legal('USD'), 'USD';
        ok !$broker->is_currency_legal('JPY'), 'JPY';
        ok !$broker->is_currency_legal('GBP'), 'GBP';
        ok !$broker->is_currency_legal('EUR'), 'EUR';
        ok !$broker->is_currency_legal('AUD'), 'AUD';
        ok !$broker->is_currency_legal('ZWD'), 'ZWD';
    };
};

cmp_deeply [sort $lc_registry->all_currencies], ['AUD', 'EUR', 'GBP', 'USD'];
