#!/usr/bin/perl

package BOM::System::Script::MarketDataStatisticCollector;

=head1 NAME

BOM::System::Script::MarketDataStatisticCollector

=head1 DESCRIPTION

To set statistic of market data. For example age of vol file, age of dividend, age of interest rates and correlation

=cut

use Moose;

use BOM::Platform::Runtime;
with 'App::Base::Script';
with 'BOM::Utility::Logging';
use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::VolSurface::Flat;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use BOM::Market::UnderlyingDB;
use BOM::Platform::Runtime;
use BOM::MarketData::CorrelationMatrix;
use Quant::Framework::ImpliedRate;
use Quant::Framework::InterestRate;
use Quant::Framework::Dividend;
use Bloomberg::CurrencyConfig;
use Try::Tiny;

sub script_run {
    my $self = shift;
    _collect_vol_ages();
    _collect_rates_ages();
    _collect_correlation_ages();
    _collect_dividend_ages();
    _collect_pipsize_stats();
    return 0;
}

sub _collect_vol_ages {

    my @quanto_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );
    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(OMXS30 IBOV KOSPI2 SPTSX60 USAAPL USGOOG USMSFT USORCL USQCOM USQQQQ frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD frxAUDSAR)
        );
    my @offered_forex = grep { not $skip_list{$_} } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'forex',
        submarket         => ['major_pairs', 'minor_pairs'],
        broker            => 'VRT',
        contract_category => 'ANY',
    );
    my @offered_others = grep { not $skip_list{$_} and $_ !~ /^SYN/ } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['indices', 'commodities'],
        broker            => 'VRT',
        contract_category => 'ANY',
    );
    my @smart_fx = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'forex',
        submarket => 'smart_fx'
    );

    my @smart_indices = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'indices',
        submarket => 'smart_index'
    );

    my @offer_underlyings = (@offered_forex, @offered_others, @smart_fx, @smart_indices);
    push @offer_underlyings,
        BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'stocks',
        contract_category => 'ANY',
        broker            => 'VRT',
        submarket         => ['france', 'belgium', 'amsterdam']);

    my @symbols = grep { !$skip_list{$_} } (@offer_underlyings, @quanto_currencies);
    foreach my $symbol (@symbols) {
        my $underlying      = BOM::Market::Underlying->new($symbol);
        next if $underlying->volatility_surface_type eq 'flat';
        my $dm              = BOM::MarketData::Fetcher::VolSurface->new;
        my $surface_in_used = $dm->fetch_surface({
            underlying => $underlying,
            cutoff     => 'New York 10:00'
        });
        my $vol_age = (time - $surface_in_used->recorded_date->epoch) / 3600;
        my $market  = $underlying->market->name;
        if ($market eq 'forex' or $market eq 'commodities') {
            if ($underlying->quanto_only) {
                $market = 'forex_quanto';
            } elsif ($underlying->submarket->name eq 'smart_fx') {
                $market = 'smart_fx';
            }
        }
        if ($market eq 'stocks') {
            $market = 'euronext';
        }

        if ($market eq 'indices' and $underlying->submarket->name eq 'smart_index') {
            $market = 'smart_index';
        }
        stats_gauge($market . '_vol_age', $vol_age, {tags => ['tag:' . $symbol]});
    }
    return;
}

sub _collect_rates_ages {

    my @implied_symbols_to_update;
    my @offer_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
        broker            => 'VRT',
    );

    my @quanto_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['forex'],
        submarket   => ['major_pairs', 'minor_pairs'],
        quanto_only => 1,
    );

    my @symbols = (@offer_currencies, @quanto_currencies);

    foreach my $symbol (@symbols) {
        my $u = BOM::Market::Underlying->new($symbol);
        next if $u->volatility_surface_type eq 'flat';
        next if not $u->forward_feed;
        my $imply_symbol      = $u->rate_to_imply;
        my $imply_from_symbol = $u->rate_to_imply_from;
        my $i_symbol          = $imply_symbol . '-' . $imply_from_symbol;
        push @implied_symbols_to_update, $i_symbol;
    }

    foreach my $implied_symbol_to_update (@implied_symbols_to_update) {
        my $rates_in_used = Quant::Framework::ImpliedRate->new(
            symbol => $implied_symbol_to_update,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );
        my $rates_age = (time - $rates_in_used->recorded_date->epoch) / 3600;
        stats_gauge('interest_rate_age', $rates_age, {tags => ['tag:' . $implied_symbol_to_update]});
    }

    my %list                 = Bloomberg::CurrencyConfig::get_interest_rate_list();
    my @currencies_to_update = keys %list;
    foreach my $currency_symbol_to_update (@currencies_to_update) {
        if ($currency_symbol_to_update eq 'XAU' or $currency_symbol_to_update eq 'XAG') {
            next;
        }
        my $currency_in_used = Quant::Framework::InterestRate->new(
            symbol => $currency_symbol_to_update,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );
        my $currency_rate_age = (time - $currency_in_used->recorded_date->epoch) / 3600;

        stats_gauge('interest_rate_age', $currency_rate_age, {tags => ['tag:' . $currency_symbol_to_update]});
    }

    my @smart_fx = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'forex',
        submarket => 'smart_fx'
    );
    foreach my $smart_fx (@smart_fx) {
        my $smart_fx_in_used = Quant::Framework::InterestRate->new(
            symbol => $smart_fx,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );
        my $smart_fx_age = (time - $smart_fx_in_used->recorded_date->epoch) / 3600;

        stats_gauge('smart_fx_interest_rate_age', $smart_fx_age, {tags => ['tag:' . $smart_fx]});
    }

    return;
}

sub _collect_correlation_ages {

    my $latest_correlation_matrix_age = time - BOM::MarketData::CorrelationMatrix->new('indices')->recorded_date->epoch;
    stats_gauge('correlation_matrix.age', $latest_correlation_matrix_age);
    return;

}

sub _collect_pipsize_stats {
    my @underlyings = map { BOM::Market::Underlying->new($_) } BOM::Market::UnderlyingDB->get_symbols_for(market => ['volidx']);
    foreach my $underlying (@underlyings) {
        my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
        my $vol = $volsurface->get_volatility({
            delta => 50,
            days  => 7
        });
        my $pipsize   = $underlying->pip_size;
        my $spot      = $underlying->spot;
        my $sigma     = sqrt($vol**2 / 365 / 86400 * 10);
        my $test_stat = $spot * $sigma / $pipsize;
        stats_gauge('test_statistic', $test_stat, {tags => ['tag:' . $underlying->{symbol}]});
    }
    return;
}

sub _collect_dividend_ages {

    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(OMXS30 USAAPL USGOOG USMSFT USORCL USQCOM USQQQQ frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD)
        );
    my @offer_indices = grep { not $skip_list{$_} and $_ !~ /^SYN/ } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['indices'],
        broker            => 'VRT',
        contract_category => 'ANY',
    );

    foreach my $index (@offer_indices) {
        my $dividend_in_used = Quant::Framework::Dividend->new(symbol => $index,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());

        my $dividend_age = (time - $dividend_in_used->recorded_date->epoch) / 3600;
        stats_gauge('dividend_rate_age', $dividend_age, {tags => ['tag:' . $index]});
    }
    return;

}

sub documentation {
    return qq{
This script is to collect a set of statistic of market data.
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;

exit BOM::System::Script::MarketDataStatisticCollector->new->run;
