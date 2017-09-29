package BOM::Pricing::v3::MarketData;

use strict;
use warnings;
no indirect;

use Try::Tiny;
use Date::Utility;
use Time::Duration::Concise::Localize;

use LandingCompany::Offerings qw(get_offerings_with_filter get_permitted_expiries);

use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime;
use BOM::Product::Contract::Offerings;

my $cache = {};

sub _get_cache {
    my ($name) = @_;
    for (keys %$cache) {
        delete $cache->{$_} if time - $cache->{$_}->{time} > 3600;
    }
    return $cache->{$name}->{value} if defined $cache->{$name}->{value};
    return;
}

sub _set_cache {
    my ($name, $value) = @_;
    $cache->{$name} = {
        time  => time,
        value => $value,
    };
    return;
}

sub _get_key {
    #check if we have actual cache, get FlyBy object and check digest
    my $digest = LandingCompany::Offerings::_get_config_key(BOM::Platform::Runtime->instance->get_offerings_config);
    my $cache_key = join ':', $digest, @_;
    return $cache_key;
}

sub trading_times {
    my $params = shift;

    my $date = try { Date::Utility->new($params->{args}->{trading_times}) } || Date::Utility->new;
    my $cache_key = _get_key('times', $date->date_ddmmmyyyy);

    my $cached = _get_cache($cache_key);
    return $cached if $cached;

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
        $market->{name} = localize($mkt->{name});
        for my $sbm (@{$mkt->{submarkets}}) {
            my $submarket = {};
            push @{$market->{submarkets}}, $submarket;
            $submarket->{name} = localize($sbm->{name});
            for my $ul (@{$sbm->{underlyings}}) {
                push @{$submarket->{symbols}},
                    {
                    name       => localize($ul->{name}),
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
    _set_cache($cache_key, {%$trading_times});
    return $trading_times,;
}

sub asset_index {
    my $params               = shift;
    my $landing_company_name = $params->{args}->{landing_company} || 'costarica';
    my $language             = $params->{language} // 'en';

    my $cache_key = _get_key($landing_company_name, $language);

    my $cached = _get_cache($cache_key);
    return $cached if $cached;

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
    _set_cache($cache_key, [@data]);
    return \@data;
}

1;
