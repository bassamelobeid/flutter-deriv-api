package BOM::Market::Script::MarketDataStatisticCollector;

=head1 NAME

BOM::Market::MarketDataStatisticCollector

=head1 DESCRIPTION

To set statistic of market data. For example age of vol file, age of dividend, age of interest rates and correlation

=cut

use Moose;

use BOM::Config::Runtime;
with 'App::Base::Script';
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::VolSurface::Flat;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use BOM::MarketData qw(create_underlying_db);
use BOM::Config::Runtime;
use Quant::Framework::CorrelationMatrix;
use Quant::Framework::ImpliedRate;
use Quant::Framework::InterestRate;
use Quant::Framework::Asset;
use Bloomberg::CurrencyConfig;
use Try::Tiny;

sub script_run {
    my $self = shift;
    _collect_vol_ages();
    _collect_rates_ages();
    _collect_correlation_ages();
    _collect_dividend_ages();
    _collect_pipsize_stats();
    _on_vol_day_stat();
    return 0;
}

sub _collect_vol_ages {

    my @quanto_currencies = create_underlying_db->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );
    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(OMXS30 IBOV KOSPI2 SPTSX60 USAAPL USGOOG USMSFT USORCL USQCOM USQQQQ frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD frxAUDSAR)
        );
    my @offered_forex = grep { not $skip_list{$_} } create_underlying_db->get_symbols_for(
        market            => 'forex',
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
    );
    my @offered_others = grep { not $skip_list{$_} and $_ !~ /^SYN/ } create_underlying_db->get_symbols_for(
        market            => ['indices', 'commodities'],
        contract_category => 'ANY',
    );
    my @smart_fx = create_underlying_db->get_symbols_for(
        market    => 'forex',
        submarket => 'smart_fx'
    );

    my @offer_underlyings = (@offered_forex, @offered_others, @smart_fx);

    my @symbols = grep { !$skip_list{$_} } (@offer_underlyings, @quanto_currencies);
    foreach my $symbol (@symbols) {
        my $underlying = create_underlying($symbol);
        next if $underlying->flat_smile;
        my $dm              = BOM::MarketData::Fetcher::VolSurface->new;
        my $surface_in_used = $dm->fetch_surface({underlying => $underlying});
        my $vol_age         = (time - $surface_in_used->creation_date->epoch) / 3600;
        my $market          = $underlying->market->name;
        if ($market eq 'forex' or $market eq 'commodities') {
            if ($underlying->quanto_only) {
                $market = 'forex_quanto';
            } elsif ($underlying->submarket->name eq 'smart_fx') {
                $market = 'smart_fx';
            }
        }

        stats_gauge($market . '_vol_age', $vol_age, {tags => ['tag:' . $symbol]});
    }
    return;
}

sub _collect_rates_ages {

    my @implied_symbols_to_update;
    my @offer_currencies = create_underlying_db->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
    );

    my @quanto_currencies = create_underlying_db->get_symbols_for(
        market      => ['forex'],
        submarket   => ['major_pairs', 'minor_pairs'],
        quanto_only => 1,
    );

    my @symbols = (@offer_currencies, @quanto_currencies);

    foreach my $symbol (@symbols) {
        my $u = create_underlying($symbol);
        next if $u->flat_smile;
        next if not $u->forward_feed;
        my $imply_symbol      = $u->rate_to_imply;
        my $imply_from_symbol = $u->rate_to_imply_from;
        my $i_symbol          = $imply_symbol . '-' . $imply_from_symbol;
        push @implied_symbols_to_update, $i_symbol;
    }

    foreach my $implied_symbol_to_update (@implied_symbols_to_update) {
        my $rates_in_used = Quant::Framework::ImpliedRate->new(
            symbol           => $implied_symbol_to_update,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
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
            symbol           => $currency_symbol_to_update,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        my $currency_rate_age = (time - $currency_in_used->recorded_date->epoch) / 3600;

        stats_gauge('interest_rate_age', $currency_rate_age, {tags => ['tag:' . $currency_symbol_to_update]});
    }

    my @smart_fx = create_underlying_db->get_symbols_for(
        market    => 'forex',
        submarket => 'smart_fx'
    );
    foreach my $smart_fx (@smart_fx) {
        my $smart_fx_in_used = Quant::Framework::InterestRate->new(
            symbol           => $smart_fx,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        my $smart_fx_age = (time - $smart_fx_in_used->recorded_date->epoch) / 3600;

        stats_gauge('smart_fx_interest_rate_age', $smart_fx_age, {tags => ['tag:' . $smart_fx]});
    }

    return;
}

sub _collect_correlation_ages {

    my $latest_correlation_matrix_age = time - Quant::Framework::CorrelationMatrix->new({
            symbol           => 'indices',
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader()})->recorded_date->epoch;
    stats_gauge('correlation_matrix.age', $latest_correlation_matrix_age);
    return;

}

sub _collect_pipsize_stats {
    my @symbols = create_underlying_db->get_symbols_for(
        market            => ['synthetic_index'],
        contract_category => 'ANY'
    );
    foreach my $symbol (@symbols) {
        my $underlying               = create_underlying($symbol);
        my $volsurface               = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
        my $vol                      = $volsurface->get_volatility();
        my $pipsize                  = $underlying->pip_size;
        my $spot                     = $underlying->spot;
        my $sigma                    = sqrt($vol**2 / 365 / 86400 * 10);
        my $quants_volidx_digit_move = $spot * $sigma / $pipsize;
        stats_gauge('quants_volidx_digit_move', $quants_volidx_digit_move, {tags => ['tag:' . $underlying->{symbol}]});
    }
    return;
}

sub _collect_dividend_ages {

    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(OMXS30 USAAPL USGOOG USMSFT USORCL USQCOM USQQQQ frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD)
        );
    my @offer_indices = grep { not $skip_list{$_} and $_ !~ /^SYN/ } create_underlying_db->get_symbols_for(
        market            => ['indices'],
        contract_category => 'ANY',
    );

    foreach my $index (@offer_indices) {
        my $dividend_in_used = Quant::Framework::Asset->new(
            symbol           => $index,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer());

        my $dividend_age = (time - $dividend_in_used->recorded_date->epoch) / 3600;
        stats_gauge('dividend_rate_age', $dividend_age, {tags => ['tag:' . $index]});
    }
    return;

}

sub _on_vol_day_stat {
    my @underlyings = map { create_underlying($_) } create_underlying_db->get_symbols_for(
        market            => 'forex',
        submarket         => 'major_pairs',
        contract_category => 'ANY',
    );

    foreach my $underlying (@underlyings) {
        my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
        my $day_for_on = $volsurface->get_day_for_tenor('ON');
        stats_gauge('On_vol_day_alert', $day_for_on, {tags => ['tag:' . $underlying->{symbol}]});
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
