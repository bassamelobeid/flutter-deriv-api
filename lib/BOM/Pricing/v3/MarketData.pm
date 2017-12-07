package BOM::Pricing::v3::MarketData;

use strict;
use warnings;
no indirect;

use Date::Utility;
use Time::Duration::Concise::Localize;
use Try::Tiny;
use List::MoreUtils qw(uniq);
use Locale::Country::Extra;

use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime;
use BOM::Platform::Chronicle;
use BOM::Product::Offerings::DisplayHelper;
use LandingCompany::Registry;

sub _get_cache {
    my ($name) = @_;
    my $v = BOM::Platform::Chronicle::get_chronicle_reader()->get('OFFERINGS', $name);
    return undef if not $v;
    if ($v->{digest} ne _get_digest()) {
        BOM::Platform::Chronicle::get_chronicle_writer()->cache_writer->del('OFFERINGS', $name);
        return undef;
    }
    return $v->{value};
}

sub _set_cache {
    my ($name, $value) = @_;
    BOM::Platform::Chronicle::get_chronicle_writer()->set(
        'OFFERINGS',
        $name,
        {
            digest => _get_digest(),
            value  => $value,
        },
        Date::Utility->new(),
        0, 86400,
    );
    return;
}

sub _get_digest {
    my $digest = _get_config_key(BOM::Platform::Runtime->instance->get_offerings_config);
    return $digest;
}

sub trading_times {
    my $params    = shift;
    my $date      = try { Date::Utility->new($params->{args}->{trading_times}) } || Date::Utility->new;
    my $language  = $params->{language} // 'en';
    my $cache_key = 'trading_times_' . $language . '_' . $date->date_yyyymmdd;

    my $cached = _get_cache($cache_key);
    return $cached if $cached;
    $cached = generate_trading_times($date);
    _set_cache($cache_key, $cached);
    return $cached;
}

sub asset_index {
    my $params               = shift;
    my $landing_company_name = $params->{args}->{landing_company} || 'costarica';
    my $language             = $params->{language} // 'en';
    my $country_code         = $params->{country_code} // '';

    my $country_name = $country_code ? Locale::Country::Extra->new->country_from_code($country_code) : '';

    for my $cache_key (map { $_ . '_asset_index_' . $language } ($country_name, $landing_company_name)) {
        if (my $cache = _get_cache($cache_key)) {
            return $cache;
        }
    }

    my ($cached, $cache_key) = generate_asset_index($country_code, $landing_company_name, $language);
    _set_cache($cache_key, $cached);
    return $cached;

}

sub generate_trading_times {
    my $date = shift;

    my $offerings = LandingCompany::Registry::get('costarica')->basic_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    my $tree      = BOM::Product::Offerings::DisplayHelper->new(
        date      => $date,
        offerings => $offerings
        )->decorate_tree(
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
    return $trading_times,;
}

sub generate_asset_index {
    my ($country_code, $landing_company_name, $language) = @_;

    my $config          = BOM::Platform::Runtime->instance->get_offerings_config;
    my $landing_company = LandingCompany::Registry::get($landing_company_name);
    my $offerings       = $landing_company->basic_offerings_for_country($country_code, $config);

    my $asset_index = BOM::Product::Offerings::DisplayHelper->new(offerings => $offerings)->decorate_tree(
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
                    _get_permitted_expiries(
                        $offerings,
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

    my $cache_key = $offerings->name . '_asset_index_' . $language;

    return (\@data, $cache_key);
}

sub _get_permitted_expiries {
    my ($offerings_obj, $args) = @_;

    my $min_field = 'min_contract_duration';
    my $max_field = 'max_contract_duration';

    my $result = {};

    return $result unless scalar keys %$args;

    my @possibles = $offerings_obj->query($args, ['expiry_type', $min_field, $max_field]);
    foreach my $actual_et (uniq map { $_->[0] } @possibles) {
        my @remaining = grep { $_->[0] eq $actual_et && $_->[1] && $_->[2] } @possibles;
        my @mins =
            ($actual_et eq 'tick')
            ? sort { $a <=> $b } map { $_->[1] } @remaining
            : sort { $a->seconds <=> $b->seconds } map { Time::Duration::Concise::Localize->new(interval => $_->[1]) } @remaining;
        my @maxs =
            ($actual_et eq 'tick')
            ? sort { $b <=> $a } map { $_->[2] } @remaining
            : sort { $b->seconds <=> $a->seconds } map { Time::Duration::Concise::Localize->new(interval => $_->[2]) } @remaining;
        $result->{$actual_et} = {
            min => $mins[0],
            max => $maxs[0],
        } if (defined $mins[0] and defined $maxs[0]);
    }

    # If they explicitly ask for a single expiry_type give just that one.
    if ($args->{expiry_type} and my $trimmed = $result->{$args->{expiry_type}}) {
        $result = $trimmed;
    }

    return $result;
}

sub _get_config_key {
    my $config_args = shift;

    my $string = "[";
    foreach my $key (sort keys %$config_args) {
        my $val = $config_args->{$key};
        $val = [$val] unless ref $val;
        $string .= $key . '-' . (join ':', sort @$val) . ';';
    }
    $string .= "]";

    return $string;
}
1;
