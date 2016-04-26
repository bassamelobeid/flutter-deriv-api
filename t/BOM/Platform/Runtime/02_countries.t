#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most 0.22 (tests => 8);
use Test::NoWarnings;
use List::Util qw(first);
use BOM::Platform::Runtime;

my $configs;
subtest 'get countries config' => sub {
    lives_ok {
        $configs = BOM::Platform::Runtime->instance->countries_list;
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

        is(BOM::Platform::Runtime->instance->restricted_country($c),            !1,    '! restricted_country');
        is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),     !1,    '!volidx _restricted_country');
        is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'fog', 'virtual_company_for_country');
        is(BOM::Platform::Runtime->instance->gaming_company_for_country($c),    'iom', 'gaming_company_for_country');
        is(BOM::Platform::Runtime->instance->financial_company_for_country($c), 'iom', 'financial_company_for_country');
    }
};

my @mlt_country = qw( at be bg cy cz dk ee fi hr hu ie lt lv nl pl pt ro se si sk );
@countries = @mlt_country;
subtest 'EU countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{gaming_company},    'malta',       'gaming company = malta');
        is($c_config->{financial_company}, 'maltainvest', 'financial company = maltainvest');

        is(BOM::Platform::Runtime->instance->restricted_country($c),            !1,            '! restricted_country');
        is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),     !1,            '! volidx_restricted_country');
        is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'fog',         'virtual_company_for_country');
        is(BOM::Platform::Runtime->instance->gaming_company_for_country($c),    'malta',       'gaming_company_for_country');
        is(BOM::Platform::Runtime->instance->financial_company_for_country($c), 'maltainvest', 'financial_company_for_country');
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

        is(BOM::Platform::Runtime->instance->restricted_country($c),            !1,            '! restricted_country');
        is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),     1,             'volidx_restricted_country');
        is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'fog',         'virtual_company_for_country');
        is(BOM::Platform::Runtime->instance->gaming_company_for_country($c),    undef,         '! gaming_company_for_country');
        is(BOM::Platform::Runtime->instance->financial_company_for_country($c), 'maltainvest', 'financial_company_for_country');
    }
};

my @restricted_country = qw( cr gg hk iq ir je kp mt my um us vi );
@countries = @restricted_country;
subtest 'restricted countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{gaming_company},    'none', 'no gaming company');
        is($c_config->{financial_company}, 'none', 'no financial company');

        is(BOM::Platform::Runtime->instance->restricted_country($c),            1,     'restricted_country');
        is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),     1,     '! volidx_restricted_country');
        is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'fog', 'virtual_company_for_country');
        is(BOM::Platform::Runtime->instance->gaming_company_for_country($c),    undef, '! gaming_company_for_country');
        is(BOM::Platform::Runtime->instance->financial_company_for_country($c), undef, '! financial_company_for_country');
    }
};

subtest 'japan' => sub {
    my $c        = 'jp';
    my $c_config = $configs->{$c};
    isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
    is($c_config->{gaming_company},    'none',  'no gaming company');
    is($c_config->{financial_company}, 'japan', 'financial company');

    is(BOM::Platform::Runtime->instance->restricted_country($c),            !1,              '! restricted_country');
    is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),     1,               'volidx_restricted_country');
    is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'japan-virtual', 'virtual_company_for_country');
    is(BOM::Platform::Runtime->instance->gaming_company_for_country($c),    undef,           '! gaming_company_for_country');
    is(BOM::Platform::Runtime->instance->financial_company_for_country($c), 'japan',         'financial_company_for_country');
};

my @exclude = (@iom_country, @mlt_country, @mf_only_country, @restricted_country, 'jp');
@countries = ();
subtest 'CR countries' => sub {
    foreach my $cc (sort keys %$configs) {
        next if (first { $cc eq $_ } @exclude);
        push @countries, $cc;
    }
    is(@countries, 205, 'CR countries count');

    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt($c_config->{name}, undef, "$c [$c_config->{name}]");
        is($c_config->{financial_company}, 'costarica', 'financial company = costarica');

        if ($c eq 'sg') {
            is($c_config->{gaming_company},                                      'none', 'Sg no gaming company');
            is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),  1,      'volidx_restricted_country');
            is(BOM::Platform::Runtime->instance->gaming_company_for_country($c), undef,  '! gaming_company_for_country');
        } else {
            is($c_config->{gaming_company},                                      'costarica', 'gaming company = costarica');
            is(BOM::Platform::Runtime->instance->volidx_restricted_country($c),  !1,          '! volidx_restricted_country');
            is(BOM::Platform::Runtime->instance->gaming_company_for_country($c), 'costarica', 'gaming_company_for_country');
        }

        is(BOM::Platform::Runtime->instance->restricted_country($c),            !1,          '! restricted_country');
        is(BOM::Platform::Runtime->instance->virtual_company_for_country($c),   'fog',       'virtual_company_for_country');
        is(BOM::Platform::Runtime->instance->financial_company_for_country($c), 'costarica', 'financial_company_for_country');
    }
};

