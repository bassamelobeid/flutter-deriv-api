
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

use BOM::User::Client;
use BOM::Platform::Context qw (localize);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Product::Offerings::DisplayHelper;
use BOM::Product::Offerings::TradingDuration qw(generate_trading_durations);
use LandingCompany::Registry;

sub _get_cache {
    my ($name) = @_;
    my $v = BOM::Config::Chronicle::get_chronicle_reader()->get('OFFERINGS', $name);
    return undef if not $v;
    if ($v->{digest} ne _get_digest()) {
        BOM::Config::Chronicle::get_chronicle_writer()->cache_writer->del('OFFERINGS', $name);
        return undef;
    }
    return $v->{value};
}

sub _set_cache {
    my ($name, $value, $cache_time) = @_;
    $cache_time = $cache_time // 86400;
    BOM::Config::Chronicle::get_chronicle_writer()->set(
        'OFFERINGS',
        $name,
        {
            digest => _get_digest(),
            value  => $value,
        },
        Date::Utility->new(),
        0,
        $cache_time,
    );
    return;
}

sub _get_digest {

    my $offerings_config     = BOM::Config::Runtime->instance->get_offerings_config();
    my $trading_calendar_rev = 0;
    my $reader               = BOM::Config::Chronicle::get_chronicle_reader();
    # information on 'Resources' are dependent on information of trading calendar. A hard cache of 1 day will
    # make information on 'Resources' out of date. Though this doesn't happen very often but we need to get this right.
    for (
        ['holidays',        'holidays'],
        ['holidays',        'manual_holidays'],
        ['partial_trading', 'early_closes'],
        ['partial_trading', 'manual_early_closes'],
        ['partial_trading', 'late_opens'],
        ['partial_trading', 'manual_late_opens'])
    {
        my $rev = $reader->get($_->[0], $_->[1] . '_revision');
        $trading_calendar_rev += $rev->{epoch} if $rev;
    }

    $offerings_config->{trading_calendar_revision} = $trading_calendar_rev;

    return _get_config_key($offerings_config);
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
    my $landing_company_name = $params->{args}{landing_company};
    my $language             = $params->{language} // 'en';
    my $country_code         = $params->{country_code} // '';

    my $token_details = $params->{token_details};

    # Set landing company with logged in client details if no arg passed
    if ($token_details and exists $token_details->{loginid} and not $landing_company_name) {
        ($landing_company_name, $country_code) = _get_info_from_token($token_details);
    }

    # Default to svg, which returns the entire asset index, if no arg and not logged in
    $landing_company_name //= 'svg';

    return generate_asset_index($country_code, $landing_company_name, $language);
}

sub trading_durations {
    my $params               = shift;
    my $landing_company_name = $params->{args}{landing_company};
    my $language             = $params->{language} // 'en';
    my $country_code         = $params->{country_code} // '';

    my $token_details = $params->{token_details};
    # Set landing company with logged in client details if no arg passed
    if ($token_details and exists $token_details->{loginid} and not $landing_company_name) {
        ($landing_company_name, $country_code) = _get_info_from_token($token_details);
    }

    $landing_company_name //= 'svg';

    my $offerings = _get_offerings($country_code, $landing_company_name);

    my $key = join '_', ($offerings->name, 'trading_durations', $language);

    if (my $cache = _get_cache($key)) {
        return $cache;
    }

    my $trading_durations = generate_trading_durations($offerings);

    # localize
    foreach my $data (@$trading_durations) {
        $data->{market}->{display_name}    = localize($data->{market}->{display_name});
        $data->{submarket}->{display_name} = localize($data->{submarket}->{display_name});
        foreach my $sub_data (@{$data->{data}}) {
            foreach my $trade_durations (@{$sub_data->{trade_durations}}) {
                $trade_durations->{trade_type}->{display_name} = localize($trade_durations->{trade_type}->{display_name});
                foreach my $duration (@{$trade_durations->{durations}}) {
                    $duration->{display_name} = localize($duration->{display_name});
                }
            }
        }
    }

    my $ttl = (60 - Date::Utility->new->minute) * 60;
    _set_cache($key, $trading_durations, $ttl);

    return $trading_durations;
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

    my $offerings = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
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

=item * landing_company_name, the name of a landing company (e.g. 'svg')

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

    my $offerings = _get_offerings($country_code, $landing_company_name);
    my $key = join '_', ($offerings->name, 'asset_index', $language);

    if (my $cache = _get_cache($key)) {
        return $cache;
    }

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

                my %times;
                foreach my $barrier_category (
                    $offerings->query({
                            contract_category => $_->code,
                            underlying_symbol => $underlying->symbol
                        },
                        ['barrier_category']))
                {
                    my %offered = %{
                        _get_permitted_expiries(
                            $offerings,
                            {
                                underlying_symbol => $underlying->symbol,
                                contract_category => $_->code,
                                barrier_category  => $barrier_category,
                            })};

                    foreach my $expiry (qw(intraday daily tick no_expiry)) {
                        if (my $included = $offered{$expiry}) {
                            foreach my $key (qw(min max)) {
                                if ($expiry eq 'no_expiry') {
                                    push @{$times{$barrier_category}}, [$included->{$key}, $included->{$key} || ''];
                                } elsif ($expiry eq 'tick') {
                                    # some tick is set to seconds somehow in this code.
                                    # don't want to waste time to figure out how it is set
                                    my $tick_count = (ref $included->{$key}) ? $included->{$key}->seconds : $included->{$key};
                                    push @{$times{$barrier_category}}, [$tick_count, $tick_count . 't'];
                                } else {
                                    $included->{$key} = Time::Duration::Concise::Localize->new(
                                        interval => $included->{$key},
                                        locale   => $language
                                    ) unless (ref $included->{$key});
                                    push @{$times{$barrier_category}}, [$included->{$key}->seconds, $included->{$key}->as_concise_string];
                                }
                            }
                        }
                    }
                    @{$times{$barrier_category}} = sort { $a->[0] <=> $b->[0] } @{$times{$barrier_category}};
                }
                return \%times;
            },
        },
    );

    # mapper for callput so that we can show the different expiries for them.
    my %barrier_category_mapper = (
        euro_atm     => ['Rise/Fall'],
        euro_non_atm => ['Higher/Lower', 2.5],
    );
    ## remove obj for json encode
    my @data;
    for my $market (@$asset_index) {
        delete $market->{$_} for (qw/obj children/);
        for my $submarket (@{$market->{submarkets}}) {
            delete $submarket->{$_} for (qw/obj parent_obj children parent/);
            for my $ul (@{$submarket->{underlyings}}) {
                delete $ul->{$_} for (qw/obj parent_obj children parent/);
                my @category_expiries;
                # just sorting by display order is not quite enough since we want contracts of different category be placed next to each other.
                # E.g. Rise/Fall Equals next to Rise/Fall.
                for my $contract_category (sort { $a->{obj}->display_order <=> $b->{obj}->display_order } @{$ul->{contract_categories}}) {
                    foreach my $barrier_category (sort keys %{$contract_category->{expiries}}) {
                        my ($name, $order) = ($contract_category->{name}, $contract_category->{obj}->display_order);
                        if ($contract_category->{code} eq 'callput') {
                            $name = localize($barrier_category_mapper{$barrier_category}->[0]);
                            $order = $barrier_category_mapper{$barrier_category}->[1] if $barrier_category_mapper{$barrier_category}->[1];
                        }
                        push @category_expiries,
                            [
                            $order,
                            [
                                $contract_category->{code},
                                $name,
                                $contract_category->{expiries}->{$barrier_category}->[0][1],
                                $contract_category->{expiries}->{$barrier_category}->[-1][1]]];
                    }
                }
                my @sorted = map { $_->[1] } sort { $a->[0] <=> $b->[0] } @category_expiries;
                my $x = [$ul->{code}, $ul->{name}, \@sorted];
                push @data, $x;
            }
        }
    }

    _set_cache($key, \@data);

    return \@data;
}

sub _get_permitted_expiries {
    my ($offerings_obj, $args) = @_;

    my $min_field = 'min_contract_duration';
    my $max_field = 'max_contract_duration';

    my $result = {};

    return $result unless scalar keys %$args;

    my @possibles = $offerings_obj->query($args, ['expiry_type', $min_field, $max_field]);
    foreach my $actual_et (uniq map { $_->[0] } @possibles) {
        my @remaining = grep { $_->[0] eq $actual_et && defined $_->[1] && defined $_->[2] } @possibles;
        my @mins =
            (
                   $actual_et eq 'tick'
                or $actual_et eq 'no_expiry'
            )
            ? sort { $a <=> $b } map { $_->[1] } @remaining
            : sort { $a->seconds <=> $b->seconds } map { Time::Duration::Concise::Localize->new(interval => $_->[1]) } @remaining;
        my @maxs =
            (
                   $actual_et eq 'tick'
                or $actual_et eq 'no_expiry'
            )
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

sub _get_info_from_token {
    my $token_details = shift;

    my $client = BOM::User::Client->new({
        loginid      => $token_details->{loginid},
        db_operation => 'replica',
    });
    # override the details here since we already have a client.
    return ($client->landing_company->short, $client->residence);
}

sub _get_offerings {
    my ($country_code, $landing_company_name) = @_;

    my $config          = BOM::Config::Runtime->instance->get_offerings_config;
    my $landing_company = LandingCompany::Registry::get($landing_company_name);

    return $landing_company->basic_offerings_for_country($country_code, $config);

}
1;
