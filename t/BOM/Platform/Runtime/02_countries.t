#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Most 0.22 (tests => 8);
use List::Util qw(first);
use BOM::Platform::Runtime;
use BOM::Platform::Countries;

my $configs;
subtest 'get countries config' => sub {
    lives_ok {
        $configs = BOM::Platform::Countries->instance->countries_list;
    }
    'get countries config ok';

    is(ref($configs),          'HASH', 'countries config is hashref');
    is(ref($configs->{id}),    'HASH', 'Indonesia config is hashref');
    is(scalar(keys %$configs), 246,    'total countries = 246');
};

my @iom_country = qw( gb im );
my @countries   = @iom_country;
subtest 'iom countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{financial_company}, 'iom', 'financial company = iom');
        is($c_config->{gaming_company},    'iom', 'gaming company = iom');

        is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,        '! restricted_country');
        is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             !1,        '!volidx _restricted_country');
        is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), !1,        '!financial_binaries _restricted_country');
        is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual', 'virtual_company_for_country');
        is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            'iom',     'gaming_company_for_country');
        is(BOM::Platform::Countries->instance->financial_company_for_country($c),         'iom',     'financial_company_for_country');
    }
};

my @mlt_country = qw( at bg cy cz dk ee fi hr hu ie lt lv nl pl pt ro se si sk );
@countries = @mlt_country;
subtest 'EU countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{gaming_company},    'malta',       'gaming company = malta');
        is($c_config->{financial_company}, 'maltainvest', 'financial company = maltainvest');

        is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,            '! restricted_country');
        is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             !1,            '! volidx_restricted_country');
        is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), !1,            '!financial_binaries _restricted_country');
        is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual',     'virtual_company_for_country');
        is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            'malta',       'gaming_company_for_country');
        is(BOM::Platform::Countries->instance->financial_company_for_country($c),         'maltainvest', 'financial_company_for_country');
    }
};

my @mf_only_country = qw( de es fr gr it lu );
@countries = @mf_only_country;
subtest 'EU countries, no Volatility Indices' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name},            undef,         "$c [$c_config->{name}]";
        is $c_config->{gaming_company},    'none',        'no gaming company';
        is $c_config->{financial_company}, 'maltainvest', 'financial company = maltainvest';

        is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,            '! restricted_country');
        is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             1,             'volidx_restricted_country');
        is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual',     'virtual_company_for_country');
        is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), !1,            '!financial_binaries _restricted_country');
        is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            undef,         '! gaming_company_for_country');
        is(BOM::Platform::Countries->instance->financial_company_for_country($c),         'maltainvest', 'financial_company_for_country');
    }
};

my @restricted_country = qw(af ba cr gg gy hk iq ir je kp la mt my sy ug um us vi vu ye pr);
@countries = @restricted_country;
subtest 'restricted countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{gaming_company},    'none', 'no gaming company');
        is($c_config->{financial_company}, 'none', 'no financial company');

        is(BOM::Platform::Countries->instance->restricted_country($c),                    1,         'restricted_country');
        is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             1,         'volidx_restricted_country');
        is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual', 'virtual_company_for_country');
        is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), 1,         'financial_binaries _restricted_country');
        is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            undef,     '! gaming_company_for_country');
        is(BOM::Platform::Countries->instance->financial_company_for_country($c),         undef,     '! financial_company_for_country');
    }
};

subtest 'japan' => sub {
    my $c        = 'jp';
    my $c_config = $configs->{$c};
    isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
    is($c_config->{gaming_company},    'none',  'no gaming company');
    is($c_config->{financial_company}, 'japan', 'financial company');

    is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,              '! restricted_country');
    is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             1,               'volidx_restricted_country');
    is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'japan-virtual', 'virtual_company_for_country');
    is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            undef,           '! gaming_company_for_country');
    is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), !1,              '!financial_binaries _restricted_country');
    is(BOM::Platform::Countries->instance->financial_company_for_country($c),         'japan',         'financial_company_for_country');
};

subtest 'belgium' => sub {
    my $c        = 'be';
    my $c_config = $configs->{$c};
    isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
    is($c_config->{gaming_company},    'malta', 'gaming company is malta');
    is($c_config->{financial_company}, 'none',  'financial compaing is none');

    is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,        '! restricted_country');
    is(BOM::Platform::Countries->instance->volidx_restricted_country($c),             !1,        '! volidx_restricted_country');
    is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual', 'virtual_company_for_country');
    is(BOM::Platform::Countries->instance->gaming_company_for_country($c),            'malta',   'gaming_company_for_country');
    is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), 1,         'financial_binaries _restricted_country');
    is(BOM::Platform::Countries->instance->financial_company_for_country($c),         undef,     '! financial_company_for_country');
};

push @mlt_country, 'be';
my @exclude = (@iom_country, @mlt_country, @mf_only_country, @restricted_country, 'jp');
@countries = ();
subtest 'CR countries' => sub {
    foreach my $cc (sort keys %$configs) {
        next if (first { $cc eq $_ } @exclude);
        push @countries, $cc;
    }
    is(@countries, 196, 'CR countries count');

    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{financial_company}, 'costarica', 'financial company = costarica');

        if ($c eq 'sg' or $c eq 'au') {
            is($c_config->{gaming_company},                                        'none', $c . ' no gaming company');
            is(BOM::Platform::Countries->instance->volidx_restricted_country($c),  1,      'volidx_restricted_country');
            is(BOM::Platform::Countries->instance->gaming_company_for_country($c), undef,  '! gaming_company_for_country');
        } else {
            is($c_config->{gaming_company},                                        'costarica', 'gaming company = costarica');
            is(BOM::Platform::Countries->instance->volidx_restricted_country($c),  !1,          '! volidx_restricted_country');
            is(BOM::Platform::Countries->instance->gaming_company_for_country($c), 'costarica', 'gaming_company_for_country');
        }

        is(BOM::Platform::Countries->instance->financial_binaries_restricted_country($c), !1,          '!financial_binaries _restricted_country');
        is(BOM::Platform::Countries->instance->restricted_country($c),                    !1,          '! restricted_country');
        is(BOM::Platform::Countries->instance->virtual_company_for_country($c),           'virtual',   'virtual_company_for_country');
        is(BOM::Platform::Countries->instance->financial_company_for_country($c),         'costarica', 'financial_company_for_country');
    }
};

