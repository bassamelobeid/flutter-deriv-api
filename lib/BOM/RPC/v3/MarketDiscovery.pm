package BOM::RPC::v3::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Date::Utility;
use Cache::RedisDB;
use Time::Duration::Concise::Localize;

use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Client::Account;
use BOM::Platform::Context qw (localize request);
use LandingCompany::Offerings;
use BOM::Platform::Runtime;
use BOM::Platform::Chronicle;
use Quant::Framework;
use LandingCompany::Registry;

sub active_symbols {
    my $params = shift;

    my $landing_company_name = $params->{args}->{landing_company} || 'costarica';
    my $product_type = $params->{args}->{product_type} // 'basic';
    my $language = $params->{language} || 'EN';
    my $token_details = $params->{token_details};

    my $client;
    if ($token_details and exists $token_details->{loginid}) {
        $client = Client::Account->new({loginid => $token_details->{loginid}});
    }

    my $offerings_obj = $client->landing_company->offerings_for_country($client->residence, BOM::Platform::Runtime->instance->get_offerings_config);

    my $appconfig_revision = BOM::Platform::Runtime->instance->app_config->current_revision;
    my ($namespace, $key) = (
        'legal_allowed_markets', join('::', ($params->{args}->{active_symbols}, $language, $offerings_obj->name, $product_type, $appconfig_revision))
    );

    my $active_symbols;
    if (my $cached_symbols = Cache::RedisDB->get($namespace, $key)) {
        $active_symbols = $cached_symbols;
    } else {
        # For multi_barrier product_type, we can only offer major forex pairs as of now.
        my @all_active =
              $product_type eq 'multi_barrier'
            ? $offerings_obj->query({submarket => 'major_pairs'}, ['underlying_symbol'])
            : $offerings_obj->values_for_key('underlying_symbol');
        # symbols would be active if we allow forward starting contracts on them.
        my %forward_starting = map { $_ => 1 } $offerings_obj->query({start_type => 'forward'}, ['underlying_symbol']);
        foreach my $symbol (@all_active) {
            my $desc = _description($symbol, $params->{args}->{active_symbols});
            $desc->{allow_forward_starting} = 1 if $forward_starting{$symbol};
            push @{$active_symbols}, $desc;
        }

        Cache::RedisDB->set($namespace, $key, $active_symbols, 30 - time % 30);
    }

    return $active_symbols;
}

sub _description {
    my $symbol           = shift;
    my $by               = shift || 'brief';
    my $ul               = create_underlying($symbol) || return;
    my $trading_calendar = eval { Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader) };
    my $iim              = $ul->intraday_interval ? $ul->intraday_interval->minutes : '';
    # sometimes the ul's exchange definition or spot-pricing is not availble yet.  Make that not fatal.
    my $exchange_is_open = $trading_calendar ? $trading_calendar->is_open_at($ul->exchange, Date::Utility->new) : '';
    my ($spot, $spot_time, $spot_age) = ('', '', '');
    if ($spot = eval { $ul->spot }) {
        $spot_time = $ul->spot_time;
        $spot_age  = $ul->spot_age;
    }
    my $response = {
        symbol                 => $symbol,
        display_name           => $ul->display_name,
        symbol_type            => $ul->instrument_type,
        market_display_name    => localize($ul->market->display_name),
        market                 => $ul->market->name,
        submarket              => $ul->submarket->name,
        submarket_display_name => localize($ul->submarket->display_name),
        exchange_is_open       => $exchange_is_open || 0,
        is_trading_suspended   => 0,
        pip                    => $ul->pip_size . "",
    };

    if ($by eq 'full') {
        $response->{exchange_name}             = $ul->exchange_name;
        $response->{delay_amount}              = $ul->delay_amount;
        $response->{quoted_currency_symbol}    = $ul->quoted_currency_symbol;
        $response->{intraday_interval_minutes} = $iim;
        $response->{spot}                      = $spot;
        $response->{spot_time}                 = $spot_time;
        $response->{spot_age}                  = $spot_age;
    }

    return $response;
}

1;
