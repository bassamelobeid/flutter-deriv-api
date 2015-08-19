#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most 0.22 (tests => 7);
use Test::NoWarnings;
use List::Util qw(first);
use BOM::Platform::Runtime;

my $configs;
subtest 'get countries config' => sub {
    lives_ok {
        $configs = BOM::Platform::Runtime->instance->countries_list;
    } 'get countries config ok';

    is ref($configs), 'HASH', 'countries config is hashref';
    is ref($configs->{id}), 'HASH', 'Indonesia config is hashref';
    is scalar (keys %$configs), 246, 'total countries = 246';
};

my @iom_country = qw( gb im );
my @countries = @iom_country;
subtest 'iom countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name}, undef, "$c [$c_config->{name}]";
        is $c_config->{financial_company}, 'iom', 'financial company = iom';
        is $c_config->{gaming_company}, undef, 'no explicit gaming company';
        is $c_config->{restricted}, undef, 'not restricted';
        is $c_config->{random_restricted}, undef, 'not random restricted';
    }
};

my @mlt_country = qw( at be bg cy cz dk ee fi hr hu lt lv nl pl pt ro se si sk );
@countries = @mlt_country;
subtest 'EU countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name}, undef, "$c [$c_config->{name}]";
        is $c_config->{gaming_company}, 'malta', 'gaming company = malta';
        is $c_config->{financial_company}, 'maltainvest', 'financial company = maltainvest';
        is $c_config->{restricted}, undef, 'not restricted';
        is $c_config->{random_restricted}, undef, 'not random restricted';
    }
};

my @mf_only_country = qw( de es fr gr ie it lu );
@countries = @mf_only_country;
subtest 'EU countries, no Random' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name}, undef, "$c [$c_config->{name}]";
        is $c_config->{gaming_company}, undef, 'no gaming company';
        is $c_config->{financial_company}, 'maltainvest', 'financial company = maltainvest';
        is $c_config->{restricted}, undef, 'not restricted';
        is $c_config->{random_restricted}, 1, 'random restricted';
    }
};

my @restricted_country = qw( cr gg hk iq ir je jp kp mt my um us vi );
@countries = @restricted_country;
subtest 'restricted countries' => sub {
    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name}, undef, "$c [$c_config->{name}]";
        is $c_config->{gaming_company}, undef, 'no gaming company';
        is $c_config->{financial_company}, undef, 'financial company = maltainvest';
        is $c_config->{restricted}, 1, 'not restricted';
        is $c_config->{random_restricted}, undef, 'no explicit random restricted';
    }
};

my @exclude = (@iom_country, @mlt_country, @mf_only_country, @restricted_country);
@countries = ();
subtest 'CR countries' => sub {
    foreach my $cc (sort keys %$configs) {
        next if (first { $cc eq $_ } @exclude);
        push @countries, $cc;
    }
    is @countries, 205, 'CR countries count';

    foreach my $c (@countries) {
        my $c_config = $configs->{$c};
        isnt $c_config->{name}, undef, "$c [$c_config->{name}]";
        is $c_config->{gaming_company}, undef, 'no explicit gaming company';
        is $c_config->{financial_company}, 'costarica', 'financial company = costarica';
        is $c_config->{restricted}, undef, 'not restricted';

        if ($c eq 'sg') {
            is $c_config->{random_restricted}, 1, 'random restricted';
        } else {
            is $c_config->{random_restricted}, undef, 'no random restricted';
        }
    }
};

