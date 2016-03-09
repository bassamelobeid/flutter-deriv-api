#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::Offerings qw(get_offerings_flyby get_offerings_with_filter);

my $fb;
my @expected_lc   = qw(japan-virtual fog costarica maltainvest japan malta iom);
my %expected_type = (
    'japan-virtual' => ['CALLE', 'NOTOUCH', 'ONETOUCH', 'PUTE', 'RANGE', 'UPORDOWN', 'EXPIRYRANGEE', 'EXPIRYMISSE'],
    fog             => [
        'ASIAND',    'ASIANU',     'CALL',       'DIGITDIFF', 'DIGITEVEN', 'DIGITMATCH', 'DIGITODD',
        'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',   'ONETOUCH',  'PUT',
        'RANGE',     'SPREADD',    'SPREADU',    'UPORDOWN',
    ],
    costarica => [
        'ASIAND',    'ASIANU',     'CALL',       'DIGITDIFF', 'DIGITEVEN', 'DIGITMATCH', 'DIGITODD',
        'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',   'ONETOUCH',  'PUT',
        'RANGE',     'SPREADD',    'SPREADU',    'UPORDOWN'
    ],
    maltainvest => ['CALL',   'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH', 'ONETOUCH', 'PUT', 'RANGE', 'UPORDOWN'],
    japan       => ['CALLE', 'NOTOUCH', 'ONETOUCH',   'PUTE',        'RANGE',   'UPORDOWN', 'EXPIRYRANGEE', 'EXPIRYMISSE'],
    malta       => [
        'ASIAND',    'ASIANU',     'CALL',       'DIGITDIFF', 'DIGITEVEN', 'DIGITMATCH', 'DIGITODD',
        'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',   'ONETOUCH',  'PUT',
        'RANGE',     'SPREADD',    'SPREADU',    'UPORDOWN'
    ],
    iom => [
        'ASIAND',    'ASIANU',     'CALL',       'DIGITDIFF', 'DIGITEVEN', 'DIGITMATCH', 'DIGITODD',
        'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',   'ONETOUCH',  'PUT',
        'RANGE',     'SPREADD',    'SPREADU',    'UPORDOWN'
    ],

);
my %expected_market = (
    'japan-virtual' => ['forex'],
    japan           => ['forex'],
    fog             => ['commodities', 'forex', 'indices', 'random', 'stocks'],
    costarica       => ['commodities', 'forex', 'indices', 'random', 'stocks'],
    maltainvest => ['commodities', 'forex', 'indices', 'stocks'],
    malta       => ['random'],
    iom => ['commodities', 'forex', 'indices', 'random', 'stocks'],
);
lives_ok { $fb = get_offerings_flyby() } 'get flyby object';
subtest 'landing_company specifics' => sub {
    lives_ok {
        my @lc = $fb->values_for_key('landing_company');
        cmp_bag(\@lc, \@expected_lc, 'get expected landing company list');
    }
    'landing company list';

    lives_ok {
        foreach my $lc (@expected_lc) {
            my @market_lc = $fb->query({landing_company => $lc}, ['market']);
            cmp_bag(\@market_lc, $expected_market{$lc}, 'market list for ' . $lc);
        }
    }
    'market list by landing company';

    lives_ok {
        foreach my $lc (@expected_lc) {
            my @type_lc = $fb->query({landing_company => $lc}, ['contract_type']);
            cmp_bag(\@type_lc, $expected_type{$lc}, 'contract type list for ' . $lc);
        }
    }
};

subtest 'offerings check' => sub {
    my %test = (
        japan => {
            'commodities' => 0,
            'forex'       => 1,
            'indices'     => 0,
            'random',     => 0,
            'stocks'      => 0
        },
        'japan-virtual' => {
            'commodities' => 0,
            'forex'       => 1,
            'indices'     => 0,
            'random',     => 0,
            'stocks'      => 0
        },
        malta => {
            'commodities' => 0,
            'forex'       => 0,
            'indices'     => 0,
            'random',     => 1,
            'stocks'      => 0
        },
        maltainvest => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'random',     => 0,
            'stocks'      => 1
        },
        fog => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'random',     => 1,
            'stocks'      => 1
        },
        iom => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'random',     => 1,
            'stocks'      => 1
        },
    );
    foreach my $testname (keys %test) {
        my $result = $test{$testname};
        foreach my $market (keys %$result) {
            if ($result->{$market}) {
                ok $fb->query({
                    landing_company => $testname,
                    market          => $market
                });
            } else {
                ok !$fb->query({
                    landing_company => $testname,
                    market          => $market
                });
            }
        }
    }
};
