#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use LandingCompany::Registry;

subtest 'legal_allowed_offerings' => sub {
    my @lc       = LandingCompany::Registry::all();
    my %expected = (
        iom             => 'common',
        malta           => 'common',
        maltainvest     => 'common',
        costarica       => 'common',
        virtual         => 'common',
        japan           => 'japan',
        'japan-virtual' => 'japan',
        vanuatu         => 'common',
    );
    for (@lc) {
        is $_->legal_allowed_offerings, $expected{$_->short}, 'correct offerings reference for landing company[' . $_->short . '].';

    }
};

done_testing();
