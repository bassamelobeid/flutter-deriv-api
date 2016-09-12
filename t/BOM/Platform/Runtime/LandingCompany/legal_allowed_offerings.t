#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Platform::LandingCompany::Registry;

subtest 'legal_allowed_offerings' => sub {
    my @lc = BOM::Platform::LandingCompany::Registry::all();
    my %expected = (
        iom => 'common_offerings',
        malta => 'common_offerings',
        maltainvest => 'common_offerings',
        costarica => 'common_offerings',
        virtual => 'common_offerings',
        japan => 'japan_offerings',
        'japan-virtual' => 'japan_offerings',
        vanuatu => 'common_offerings',
    );
    for (@lc) {
        is $_->legal_allowed_offerings, $expected{$_->short}, 'correct offerings reference for landing company['.$_->short.'].';

    }
};

done_testing();
