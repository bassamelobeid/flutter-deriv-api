package BOM::WebSocketAPI::v3::MarketDiscovery;

use strict;
use warnings;

use Date::Utility;
use List::MoreUtils qw(any none);
use Time::Duration::Concise::Localize;

use BOM::WebSocketAPI::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Product::Contract::Offerings;
use BOM::Product::Offerings qw(get_offerings_with_filter get_permitted_expiries);

sub trading_times {
    my $args = shift;

    my $date = try { Date::Utility->new($args->{trading_times}) } || Date::Utility->new;
    my $tree = BOM::Product::Contract::Offerings->new(date => $date)->decorate_tree(
        markets     => {name => 'name'},
        submarkets  => {name => 'name'},
        underlyings => {
            name         => 'name',
            times        => 'times',
            events       => 'events',
            symbol       => sub { $_->symbol },
            feed_license => sub { $_->feed_license },
            delay_amount => sub { $_->delay_amount },
        });
    my $trading_times = {};
    for my $mkt (@$tree) {
        my $market = {};
        push @{$trading_times->{markets}}, $market;
        $market->{name} = $mkt->{name};
        for my $sbm (@{$mkt->{submarkets}}) {
            my $submarket = {};
            push @{$market->{submarkets}}, $submarket;
            $submarket->{name} = $sbm->{name};
            for my $ul (@{$sbm->{underlyings}}) {
                push @{$submarket->{symbols}},
                    {
                    name       => $ul->{name},
                    symbol     => $ul->{symbol},
                    settlement => $ul->{settlement} || '',
                    events     => $ul->{events},
                    times      => $ul->{times},
                    ($ul->{feed_license} ne 'realtime') ? (feed_license => $ul->{feed_license}) : (),
                    ($ul->{delay_amount} > 0)           ? (delay_amount => $ul->{delay_amount}) : (),
                    };
            }
        }
    }
    return $trading_times,;
}

sub asset_index {
    my ($language, $args) = @_;

    my $asset_index = BOM::Product::Contract::Offerings->new->decorate_tree(
        markets => {
            code => sub { $_->name },
            name => sub { $_->translated_display_name }
        },
        submarkets => {
            code => sub {
                $_->name;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        underlyings => {
            code => sub {
                $_->symbol;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        contract_categories => {
            code => sub {
                $_->code;
            },
            name => sub {
                $_->translated_display_name;
            },
            expiries => sub {
                my $underlying = shift;
                my %offered    = %{
                    get_permitted_expiries({
                            underlying_symbol => $underlying->symbol,
                            contract_category => $_->code,
                        })};

                my @times;
                foreach my $expiry (qw(intraday daily tick)) {
                    if (my $included = $offered{$expiry}) {
                        foreach my $key (qw(min max)) {
                            if ($expiry eq 'tick') {
                                # some tick is set to seconds somehow in this code.
                                # don't want to waste time to figure out how it is set
                                my $tick_count = (ref $included->{$key}) ? $included->{$key}->seconds : $included->{$key};
                                push @times, [$tick_count, $tick_count . 't'];
                            } else {
                                $included->{$key} = Time::Duration::Concise::Localize->new(
                                    interval => $included->{$key},
                                    locale   => $language
                                ) unless (ref $included->{$key});
                                push @times, [$included->{$key}->seconds, $included->{$key}->as_concise_string];
                            }
                        }
                    }
                }
                @times = sort { $a->[0] <=> $b->[0] } @times;
                return +{
                    min => $times[0][1],
                    max => $times[-1][1],
                };
            },
        },
    );

    ## remove obj for json encode
    my @data;
    for my $market (@$asset_index) {
        delete $market->{$_} for (qw/obj children/);
        for my $submarket (@{$market->{submarkets}}) {
            delete $submarket->{$_} for (qw/obj parent_obj children parent/);
            for my $ul (@{$submarket->{underlyings}}) {
                delete $ul->{$_} for (qw/obj parent_obj children parent/);
                for (@{$ul->{contract_categories}}) {
                    $_ = [$_->{code}, $_->{name}, $_->{expiries}->{min}, $_->{expiries}->{max}];
                }
                my $x = [$ul->{code}, $ul->{name}, $ul->{contract_categories}];
                push @data, $x;
            }
        }
    }

    return \@data;
}

sub _description {
    my $symbol = shift;
    my $by     = shift || 'brief';
    my $ul     = BOM::Market::Underlying->new($symbol) || return;
    my $iim    = $ul->intraday_interval ? $ul->intraday_interval->minutes : '';
    # sometimes the ul's exchange definition or spot-pricing is not availble yet.  Make that not fatal.
    my $exchange_is_open = eval { $ul->exchange } ? $ul->exchange->is_open_at(time) : '';
    my ($spot, $spot_time, $spot_age) = ('', '', '');
    if ($spot = eval { $ul->spot }) {
        $spot_time = $ul->spot_time;
        $spot_age  = $ul->spot_age;
    }
    my $response = {
        symbol                 => $symbol,
        display_name           => $ul->display_name,
        symbol_type            => $ul->instrument_type,
        market_display_name    => $ul->market->translated_display_name,
        market                 => $ul->market->name,
        submarket              => $ul->submarket->name,
        submarket_display_name => $ul->submarket->translated_display_name,
        exchange_is_open       => $exchange_is_open || 0,
        is_trading_suspended   => $ul->is_trading_suspended,
        pip                    => $ul->pip_size
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

sub active_symbols {
    my ($client, $args) = @_;

    my $landing_company_name = 'costarica';
    if ($client) {
        $landing_company_name = $client->landing_company->short;
    }
    my $legal_allowed_markets = BOM::Platform::Runtime::LandingCompany::Registry->new->get($landing_company_name)->legal_allowed_markets;

    return [
        map { $_ }
            grep {
            my $market = $_->{market};
            grep { $market eq $_ } @{$legal_allowed_markets}
            }
            map {
            _description($_, $args->{active_symbols})
            } get_offerings_with_filter('underlying_symbol')];
}

1;
