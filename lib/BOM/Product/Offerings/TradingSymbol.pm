package BOM::Product::Offerings::TradingSymbol;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_symbols);

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);
use BOM::Product::Exception;

use LandingCompany::Registry;
use Cache::RedisDB;
use Finance::Underlying;
use Quant::Framework;
use Date::Utility;
use Brands;

use constant NAMESPACE => 'TRADING_SYMBOL';

=head2 get_symbols

Returns a array reference of trading symbols for the given parameters

=over 4

=item * landing_company_name - landing company short name (required, default to virtual)

=item * country_code - 2-letter country code

=item * app_id - application id

=back

=cut

sub get_symbols {
    my $args = shift;

    my $landing_company_name = $args->{landing_company_name} // 'virtual';
    my $type                 = $args->{type}                 // 'full';
    my $landing_company      = LandingCompany::Registry->by_name($landing_company_name);

    BOM::Product::Exception->throw(error_code => 'OfferingsInvalidLandingCompany') unless ($landing_company);

    my $country_code       = $args->{country_code};
    my $runtime            = BOM::Config::Runtime->instance;
    my $appconfig_revision = $runtime->app_config->loaded_revision // 0;
    my $brands             = $args->{brands}                       // Brands->new;
    my $app_offerings      = defined $args->{app_id} ? $brands->get_app($args->{app_id})->offerings() : 'default';

    my $active_symbols = [];    # API response expects an array eventhough it is empty

    my $offerings_obj;
    if ($country_code) {
        $offerings_obj = $landing_company->basic_offerings_for_country($country_code, $runtime->get_offerings_config, $app_offerings);
    } else {
        $offerings_obj = $landing_company->basic_offerings($runtime->get_offerings_config, $app_offerings);
    }

    my ($namespace, $key) = ('trading_symbols', join('::', ($offerings_obj->name, $appconfig_revision, $app_offerings)));

    if (my $cached_symbols = Cache::RedisDB->get($namespace, $key)) {
        $active_symbols = $cached_symbols;
    } else {
        my @all_active = $offerings_obj->values_for_key('underlying_symbol');
        # symbols would be active if we allow forward starting contracts on them.
        my %forward_starting = map { $_ => 1 } $offerings_obj->query({start_type => 'forward'}, ['underlying_symbol']);
        foreach my $symbol (@all_active) {
            my $desc = _description($symbol) or next;
            $desc->{allow_forward_starting} = $forward_starting{$symbol} ? 1 : 0;
            push @{$active_symbols}, $desc;
        }

        my $cache_interval = 30;
        Cache::RedisDB->set($namespace, $key, $active_symbols, $cache_interval - time % $cache_interval);
    }

    return {symbols => $type eq 'brief' ? _trim($active_symbols) : $active_symbols};
}

=head2 _trim

Trim active symbols to return brief information.

=cut

{
    my @brief =
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting);

    sub _trim {
        my $active_symbols = shift;

        my @trimmed;
        foreach my $details ($active_symbols->@*) {
            push @trimmed, +{map { $_ => $details->{$_} } @brief};
        }

        return \@trimmed;
    }
}

=head2 _description

Returns an hash reference of configuration details for a symbol

=cut

sub _description {
    my $symbol = shift;

    my $ul               = create_underlying($symbol) || return;
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $exchange_is_open = $trading_calendar->is_open_at($ul->exchange, Date::Utility->new);
    my $response         = {
        symbol                    => $symbol,
        display_name              => $ul->display_name,
        symbol_type               => $ul->instrument_type,
        market_display_name       => $ul->market->display_name,
        market                    => $ul->market->name,
        submarket                 => $ul->submarket->name,
        submarket_display_name    => $ul->submarket->display_name,
        exchange_is_open          => $exchange_is_open || 0,
        is_trading_suspended      => 0,                                 # please remove this if we ever move to a newer API version of active_symbols
        pip                       => $ul->pip_size . "",
        exchange_name             => $ul->exchange_name,
        delay_amount              => $ul->delay_amount,
        quoted_currency_symbol    => $ul->quoted_currency_symbol,
        intraday_interval_minutes => $ul->intraday_interval->minutes,
        spot                      => $ul->spot,
        spot_time                 => $ul->spot_time // '',
        spot_age                  => $ul->spot_age,
    };

    return $response;
}

1;
