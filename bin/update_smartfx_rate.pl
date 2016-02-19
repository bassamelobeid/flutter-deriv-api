#!/usr/bin/perl
package BOM::System::Script::UpdateSmartFxRates;

=head1 NAME

BOM::System::Script::UpdateVol;

=head1 DESCRIPTION

Updates our vols with the latest quotes we have received from Bloomberg.

=cut

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use YAML::CacheLoader;
use List::Util qw(first);
use BOM::Market::Underlying;
use Quant::Framework::InterestRate;
use Date::Utility;

use JSON qw(from_json);

has world_symbols => (
    is => 'ro',
    default => sub {{
        WLDUSD => {
            source => [qw(frxEURUSD frxUSDJPY frxGBPUSD frxUSDCAD frxAUDUSD)],
            negative => [qw(frxGBPUSD frxEURUSD)]},
        WLDAUD => {
            source => [qw(frxAUDCAD frxAUDJPY frxAUDUSD frxEURAUD frxGBPAUD)],
            negative => [qw(frxEURAUD frxGBPAUD)],},
        WLDEUR => {
            source => [qw(frxEURAUD frxEURCAD frxEURGBP frxEURJPY frxEURUSD)],
            negative => [qw()],
            },
        WLDGBP => {
            source => [qw(frxEURGBP frxGBPAUD frxGBPCAD frxGBPJPY frxGBPUSD)],
            negative => [qw(EURGBP)],
        },
    }},
);

sub documentation {
    return 'updates smart fx interest rates.';
}

sub script_run {
    my $self = shift;

    my $world = $self->world_symbols;
    my @smart_symbols = keys %$world;
    foreach my $symbol (@smart_symbols) {
        my %neg = map {$_ => 1} @{$world->{$symbol}->{negative}};
        my $date = Date::Utility->new();
        next if $date->is_a_weekend;
        my @source = map {BOM::Market::Underlying->new($_)} @{$self->world_symbols->{$symbol}->{source}};
        my %world_rate;
        for my $term (sort {$a <=> $b} keys %{Quant::Framework::InterestRate->new({symbol => 'USD'})->rates}) {
	    my %rates = map {$_->symbol => $_->interest_rate_for($term/365) - $_->dividend_rate_for($term/365)} @source;
	    my @rates_array = map {$neg{$_->symbol} ? -$rates{$_->symbol} : $rates{$_->symbol}} @source;
	    $world_rate{$term} = ($rates_array[0] + $rates_array[1] + $rates_array[2] + $rates_array[3] + $rates_array[4])/5;
        }
        my $ir      = Quant::Framework::InterestRate->new({
          symbol          => $symbol,
          rates             => \%world_rate,
          recorded_date       => $date
        });
        $ir->save;
    }

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
package main;
exit BOM::System::Script::UpdateSmartFxRates->new->run;
1;
