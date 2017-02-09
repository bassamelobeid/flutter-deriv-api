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
use BOM::Product::Contract::Offerings;
use LandingCompany::Offerings qw(get_offerings_with_filter get_permitted_expiries);
use BOM::Platform::Runtime;

my %name_mapper = (
    DVD_STOCK  => localize('Stock Dividend'),
    STOCK_SPLT => localize('Stock Split'),
);

sub get_corporate_actions {
    my $params = shift;

    my $symbol = $params->{args}->{symbol};
    my $start  = $params->{args}->{start};
    my $end    = $params->{args}->{end};

    my ($start_date, $end_date);

    my $response = {
        actions => [],
        count   => 0
    };

    if (not $end) {
        $end_date = Date::Utility->new;
    } else {
        $end_date = Date::Utility->new($end);
    }

    if (not $start) {
        $start_date = $end_date->minus_time_interval('365d');
    } else {
        $start_date = Date::Utility->new($start);
    }

    if ($start_date->is_after($end_date)) {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
            code              => "GetCorporateActionsFailure"
        });

        return $response;
    }

    try {
        my @actions;
        my $underlying = create_underlying($symbol);

        if ($underlying->market->affected_by_corporate_actions) {
            @actions = $underlying->get_applicable_corporate_actions_for_period({
                start => $start_date,
                end   => $end_date,
            });
        }

        my @corporate_actions;
        foreach my $action (@actions) {
            my $display_date = Date::Utility->new($action->{effective_date})->date_ddmmmyyyy;

            my $struct = {
                display_date => $display_date,
                type         => $name_mapper{$action->{type}},
                value        => $action->{value},
                modifier     => $action->{modifier},
            };

            push @corporate_actions, $struct;
        }

        if (scalar(@corporate_actions)) {
            $response = {
                actions => \@corporate_actions,
            };
        }
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
            code              => "GetCorporateActionsFailure"
        });
    };

    return $response;
}

sub trading_times {
    my $params = shift;

    my $date = try { Date::Utility->new($params->{args}->{trading_times}) } || Date::Utility->new;
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
    my $params = shift;

    my $landing_company_name = $params->{args}->{landing_company} || 'costarica';

    my $asset_index = BOM::Product::Contract::Offerings->new(landing_company => $landing_company_name)->decorate_tree(
        markets => {
            code => sub { $_->name },
            name => sub { localize($_->display_name) }
        },
        submarkets => {
            code => sub {
                $_->name;
            },
            name => sub {
                localize($_->display_name);
            }
        },
        underlyings => {
            code => sub {
                $_->symbol;
            },
            name => sub {
                localize($_->display_name);
            }
        },
        contract_categories => {
            code => sub {
                $_->code;
            },
            name => sub {
                localize($_->display_name);
            },
            expiries => sub {
                my $underlying = shift;
                my %offered    = %{
                    get_permitted_expiries(
                        BOM::Platform::Runtime->instance->get_offerings_config,
                        {
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
                                    locale   => $params->{language}) unless (ref $included->{$key});
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

sub active_symbols {
    my $params = shift;

    my $landing_company_name = $params->{args}->{landing_company} || 'costarica';
    my $product_type = $params->{args}->{product_type} // 'basic';
    my $language = $params->{language} || 'EN';
    my $token_details = $params->{token_details};
    if ($token_details and exists $token_details->{loginid}) {
        my $client = Client::Account->new({loginid => $token_details->{loginid}});
        $landing_company_name = $client->landing_company->short if $client;
    }

    my $appconfig_revision = BOM::Platform::Runtime->instance->app_config->current_revision;
    my ($namespace, $key) = (
        'legal_allowed_markets', join('::', ($params->{args}->{active_symbols}, $language, $landing_company_name, $product_type, $appconfig_revision))
    );

    my $active_symbols;
    if (my $cached_symbols = Cache::RedisDB->get($namespace, $key)) {
        $active_symbols = $cached_symbols;
    } else {
        my $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;
        my $offerings_args = {landing_company => $landing_company_name};
        # For multi_barrier product_type, we can only offer major forex pairs as of now.
        $offerings_args->{submarket} = 'major_pairs' if $product_type eq 'multi_barrier';
        my @all_active = get_offerings_with_filter($offerings_config, 'underlying_symbol', $offerings_args);
        # symbols would be active if we allow forward starting contracts on them.
        my %forward_starting = map { $_ => 1 } get_offerings_with_filter(
            $offerings_config,
            'underlying_symbol',
            {
                landing_company => $landing_company_name,
                start_type      => 'forward'
            });
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
    my $symbol = shift;
    my $by     = shift || 'brief';
    my $ul     = create_underlying($symbol) || return;
    my $iim    = $ul->intraday_interval ? $ul->intraday_interval->minutes : '';
    # sometimes the ul's exchange definition or spot-pricing is not availble yet.  Make that not fatal.
    my $exchange_is_open = eval { $ul->calendar } ? $ul->calendar->is_open_at(time) : '';
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

1;
