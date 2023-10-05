#!/usr/bin/perl

use strict;
use warnings;
use BOM::Product::Offerings::DisplayHelper::Options;
use BOM::Product::Offerings::DisplayHelper::CFD;

use LandingCompany::Registry;
use Test::More;

my $basic_offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings({loaded_revision => 0, action => 'buy'});

subtest 'offerings with CFD must be larger than BO/Multiplier' => sub {
    my $offerings_tree          = BOM::Product::Offerings::DisplayHelper::Options->new(offerings => $basic_offerings)->decorate_tree();
    my $offerings_tree_with_cfd = BOM::Product::Offerings::DisplayHelper::CFD->new(offerings => $basic_offerings)->decorate_tree();

    my @underlyings          = ();
    my @underlyings_with_cfd = ();

    for my $mkt ($offerings_tree->@*) {
        for my $submkt ($mkt->{submarkets}->@*) {
            for my $underlying ($submkt->{underlyings}->@*) {
                push @underlyings, $underlying->{obj}->{display_name};
            }
        }
    }

    for my $mkt ($offerings_tree_with_cfd->@*) {
        for my $submkt ($mkt->{submarkets}->@*) {
            for my $underlying ($submkt->{underlyings}->@*) {
                push @underlyings_with_cfd, $underlying->{obj}->{display_name};
            }
        }
    }

    is scalar(@underlyings) < scalar(@underlyings_with_cfd), 1, 'offerings with CFD must be larger than BO/Multiplier';

};

done_testing();
