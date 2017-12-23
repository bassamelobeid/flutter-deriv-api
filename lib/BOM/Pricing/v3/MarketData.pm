
=head1 NAME

BOM::Pricing::v3::MarketData

=head1 DESCRIPTION

Package containing functions to obtain market data.

=cut

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
use LandingCompany::Offerings;

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

=head2 trading_times

    $trading_times = trading_times({trading_times => $date})

Given a date, returns the trading times of the trading markets for that date.BOM::Pricing::v3::MarketData

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * args, which may contain the following keys:

=over 4

=item * trading_times (a string containing a date in yyyy-mm-dd format, or "today")

=back

=back

Returns a hashref containing values returned by the generate_trading_times($date) subroutine.

=cut

sub trading_times {
    my $params = shift;
    my $date;

    if ($params->{args}->{trading_times} eq 'today') {
        $date = Date::Utility->new;
    } else {
        $date = try { Date::Utility->new($params->{args}->{trading_times}) };
    }

    unless ($date) {
        return BOM::Pricing::v3::Utility::create_error({
                code              => 'InvalidDateFormat',
                message_to_client => localize('Invalid date format.')});
    }

    my $language = $params->{language} // 'en';
    my $cache_key = 'trading_times_' . $language . '_' . $date->date_yyyymmdd;

    my $cached = _get_cache($cache_key);
    return $cached if $cached;
    $cached = generate_trading_times($date);
    _set_cache($cache_key, $cached);
    return $cached;
}

=head2 asset_index

    $asset_index = asset_index({
        'landing_company' => $landing_company_name,
        'language'        => $language,
        'country_code'    => $country_code,
        });

Returns a list of all available markets and a summary of the contracts available for those markets.

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * language, a 2-letter language code

=item * country_code, a 2-letter country code

=item * args, which contains the following keys:

=over 4

=item * landing_company, the landing company name

=back

=back

Returns an arrayref containing values returned by the generate_asset_index($country_code, $landing_company_name, $language) subroutine.

=cut

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

=head2 generate_trading_times

    $trading_times = generate_trading_times($date)

Returns a hashref containing market trading times.

Accepts a Date::Utility object, $date.

Returns a hashref containing the following:

=over 4

=item * markets, an arrayref containing a hashref that represents the various markets (e.g. Forex, OTC Stocks). Each hashref contains the following:

=over 4

=item * name (e.g. Forex, OTC)

=item * submarkets, an arrayref containing a hashref that represents the various symbols/underlyings. Each hashref contains the following:

=over 4

=item * events, an arrayref containing hashrefs that contain economic events affecting this symbol. Each hashref contains:

=over 4

=item * dates, a string containing the dates of the associated event

=item * descrip, a string containing the description of the event

=back

=item * name, the name of a symbol (e.g. "AUD/JPY", "AUD/USD")

=item * symbol, the underlying symbol (e.g. "frxAUDJPY", "frxAUDUSD")

=item * times, a hashref containing the following values:

=over 4

=item * open, an arrayref containing a string representing the market opening time in the HH:MM:SS format

=item * close, an arrayref containing a string representing the market closing time in the HH:MM:SS format

=item * settlement, a string representing the settlement time for contracts in the HH:MM:SS format

=back

=back

=back

=back

=cut

sub generate_trading_times {
    my $date = shift;

    my $offerings = LandingCompany::Offerings->get('costarica', BOM::Platform::Runtime->instance->get_offerings_config);
    my $tree = BOM::Product::Offerings::DisplayHelper->new(
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
                    name   => localize($ul->{name}),
                    symbol => $ul->{symbol},
                    events => $ul->{events},
                    times  => $ul->{times},
                    ($ul->{feed_license} ne 'realtime') ? (feed_license => $ul->{feed_license}) : (),
                    ($ul->{delay_amount} > 0)           ? (delay_amount => $ul->{delay_amount}) : (),
                    };
            }
        }
    }
    return $trading_times,;
}

=head2 generate_asset_index

    $asset_index = generate_asset_index($country_code, $landing_company_name, $language)

Returns a a list of all available markets for a given landing company and a summary of available contracts for purchase.

Takes the following scalars:

=over 4

=item * language, a 2-letter language code

=item * country_code, a 2-letter country code (e.g. 'id')

=item * landing_company_name, the name of a landing company (e.g. 'costarica')

=back

Returns an arrayref, where each array element contains the following values (in order):

=over 4

=item * underlying (e.g. frxAUDJPY)

=item * symbol (e.g. AUD/JPY)

=item * an arrayref containing the various contract categories. Each arrayref contains arrayrefs with the following entries:

=over 4

=item * contract_code, the internal code for the contract type

=item * contract_name, the name of the contract

=item * min_expiry, the minimum expiry time of the contract

=item * max_expiry, the maximum expiry time of the contract

=back

=back

=cut

sub generate_asset_index {
    my ($country_code, $landing_company_name, $language) = @_;

    my $config = BOM::Platform::Runtime->instance->get_offerings_config;
    my $offerings = LandingCompany::Offerings->get($country_code, $config) // LandingCompany::Offerings->get($landing_company_name, $config);

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
