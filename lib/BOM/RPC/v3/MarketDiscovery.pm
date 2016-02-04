package BOM::RPC::v3::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Date::Utility;
use Time::Duration::Concise::Localize;

use BOM::RPC::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Client;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Product::Contract::Offerings;
use BOM::Product::Offerings qw(get_offerings_with_filter get_permitted_expiries);
use BOM::System::RedisReplicated;
use Sereal::Encoder;

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

    my $client;
    my $landing_company_name = 'costarica';
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
        $landing_company_name = $client->landing_company->short if $client;
    }

    my $legal_allowed_markets = BOM::Platform::Runtime::LandingCompany::Registry->new->get($landing_company_name)->legal_allowed_markets;

    my $uuid =
        'legal_allowed_markets::' . $params->{args}->{active_symbols} . '::' . $params->{language} . '::' . join(",", sort @$legal_allowed_markets);

    my $active_symbols;
    if ($active_symbols = BOM::System::RedisReplicated::redis_read()->get($uuid)
        and BOM::System::RedisReplicated::redis_read->ttl($uuid) > 0)
    {
        $active_symbols = JSON::from_json(Sereal::Decoder->new->decode($active_symbols));
    } else {
        my %allowed_market;
        undef @allowed_market{@$legal_allowed_markets};
        $active_symbols = [
            map {
                my $descr = _description($_, $params->{args}->{active_symbols});
                exists $allowed_market{$descr->{market}} ? $descr : ();
            } get_offerings_with_filter('underlying_symbol')];

        BOM::System::RedisReplicated::redis_write()->set($uuid, Sereal::Encoder->new->encode(JSON::to_json($active_symbols)));
        #expire in nearest 5 minute interval
        BOM::System::RedisReplicated::redis_write()->expire($uuid, 300 - time % 300);
    }

    return $active_symbols;
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

1;
