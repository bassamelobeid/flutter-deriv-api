#!/usr/bin/perl

use strict;
use warnings;
use BOM::Product::Offerings::DisplayHelper::Options;

use Data::Chronicle::Mock;
use LandingCompany::Registry;
use Test::More;

my $basic_offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings({loaded_revision => 0, action => 'buy'});

subtest 'Suspended offerings should not be in the list' => sub {

    suspend_symbol();
    my $offerings_tree_with_cfd = BOM::Product::Offerings::DisplayHelper::Options->new(offerings => $basic_offerings)->decorate_tree();

    my @underlyings_with_cfd = ();

    for my $mkt ($offerings_tree_with_cfd->@*) {
        for my $submkt ($mkt->{submarkets}->@*) {
            for my $underlying ($submkt->{underlyings}->@*) {
                push @underlyings_with_cfd, $underlying->{obj}->{display_name};
            }
        }
    }

    my @suspended_symbols = grep { $_ eq 'USD/JPY DFX10 Index' or $_ eq 'AUD/USD DFX20 Index' } @underlyings_with_cfd;
    is scalar(@suspended_symbols), 0, "Shouldn't have USD/JPY DFX10 Index and AUD/USD DFX20 Index";
};

sub suspend_symbol {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    my ($chronicle_r, $chronicle_w) = Data::Chronicle::Mock::get_mocked_chronicle();

    $app_config->chronicle_writer($chronicle_w);
    $app_config->set({'quants.underlyings.suspend_buy' => ['USDJPYDFX10', 'AUDUSDDFX20']});

}

done_testing();
