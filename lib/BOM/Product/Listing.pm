package BOM::Product::Listing;

use strict;
use warnings;

use Moo;

use BOM::Config::Runtime;
use LandingCompany::Registry;
use Brands;
use BOM::Config::MT5;
use Brands::Countries;
use JSON::MaybeXS qw(decode_json);
use List::Util    qw(uniq first);
use Finance::Underlying::Market::Registry;
use Finance::Underlying::SubMarket::Registry;
use Finance::Underlying;

=head2 brand_name

The brand name. Default to deriv.

=cut

has brand_name => (
    is      => 'ro',
    default => 'deriv',
);

=head2 app_mapper

Application information mapper.

=cut

has app_mapper => (
    is      => 'ro',
    default => sub {
        return {
            binary_bot         => \&_deriv_listing,
            binary_smarttrader => \&_deriv_listing,
            binary_webtrader   => \&_deriv_listing,
            binary_ticktrade   => \&_deriv_listing,
            deriv_bot          => \&_deriv_listing,
            deriv_dtrader      => \&_deriv_listing,
            deriv_go           => \&_deriv_listing,
            derivez            => \&_deriv_listing,
            ctrader            => \&_deriv_listing,
            deriv_smarttrader  => \&_deriv_listing,
            deriv_binarybot    => \&_deriv_listing,
            mt5                => \&_mt5_listing,
            default            => \&_deriv_listing,
            none               => \&_empty_listing,
        };
    },
);

=head2 mt5_market_mapper

Market mapper between MT5 and Deriv application.

=cut

has mt5_market_mapper => (
    is      => 'ro',
    default => sub {
        return {
            'Crypto'             => 'cryptocurrency',
            'Crypto_MF'          => 'cryptocurrency',
            'Forex Minor'        => 'forex',
            'Forex'              => 'forex',
            'Equities'           => 'stocks',
            'Energies'           => 'commodities',
            'Forex Micro'        => 'forex',
            'Range Break'        => 'synthetic_index',
            'Volatility Indices' => 'synthetic_index',
            'Forex_IV'           => 'forex',
            'Stock Indices'      => 'indices',
            'CFDIndices'         => 'indices',
            'SmartFX Indices'    => 'synthetic_index',
            'Crash Boom Indices' => 'synthetic_index',
            'Metals'             => 'commodities',
            'Step Indices'       => 'synthetic_index',
            'Forex Major'        => 'forex',
            'Forex_III'          => 'forex',
            'Forex_II'           => 'forex',
        };
    },
);

=head2 by_country

Get product listing by country

=over 4

=item * country_code - 2-letter country code

=item * app id - app id

=back

Returns a hash reference of product listing in the following structure:

{
    deriv_bot => {
        name => 'DBot',
        available_markets => ['Forex', 'Commodities', ...],
        available_trade_types => ['Options', ..],
        product_list => [
            {
              "available_account_types": [
                "Standard"
              ],
              "available_trade_types": [
                "Options"
              ],
              "display_market": "Commodities",
              "display_name": "Platinum/USD",
              "display_submarket": "Metals",
              "market": "commodities",
              "name": "frxXPTUSD",
              "submarket": "metals"
            },
            ...
        ]
    },
    deriv_dtrader => {
        ...
    }
}

=cut

sub by_country {
    my ($self, $country_code, $app_id) = @_;

    # brand is default to deriv
    my $countries = $self->countries_instance->countries_list();

    unless ($country_code) {
        return {
            error_code        => 'UndefinedCountryCode',
            message           => 'country_code is undefined',
            message_to_client => 'Country code is required.'
        };
    }

    if ($country_code and not $countries->{$country_code}) {
        return {
            error_code        => 'InvalidCountryCode',
            message           => 'country_code is invalid',
            message_to_client => 'Country code is invalid.'
        };
    }

    my @apps;
    if ($app_id) {
        @apps = map { $self->brand->get_app($_) } $app_id->@*;
    } else {
        @apps = grep { $_->offerings ne 'none' } values $self->brand->whitelist_apps->%*;
    }

    my %listing;
    foreach my $app (@apps) {
        die 'unknown app ' . $app->offerings unless $self->app_mapper->{$app->offerings};
        $listing{$app->id} = $self->app_mapper->{$app->offerings}->($self, $country_code, $app);
    }

    return \%listing;
}

=head2 _deriv_listing

Process product listing for Deriv's applications.

Listing defined in product offerings by landing company.

=cut

sub _deriv_listing {
    my ($self, $country_code, $app) = @_;

    # offerings config for action=buy
    my $offerings_config   = BOM::Config::Runtime->instance->get_offerings_config('buy');
    my $market_registry    = Finance::Underlying::Market::Registry->instance;
    my $submarket_registry = Finance::Underlying::SubMarket::Registry->instance;
    my $country_config     = $self->countries_instance->countries_list->{$country_code};

    # deriv
    my %result;
    my @lc_short = uniq grep { $_ ne 'none' } map { $country_config->{$_} } qw(financial_company gaming_company);
    my (@available_markets, @available_trade_types, %product_list);
    foreach my $landing_company (map { LandingCompany::Registry->by_name($_) } @lc_short) {
        my $offerings = $landing_company->basic_offerings_for_country($country_code, $offerings_config, $app->offerings);
        foreach my $market ($offerings->values_for_key('market')) {
            my $market_obj = $market_registry->get($market);
            push @available_markets, $market_obj->display_name;
            foreach my $submarket ($offerings->query({market => $market}, ['submarket'])) {
                my $submarket_obj = $submarket_registry->get($submarket);
                foreach my $symbol (
                    $offerings->query({
                            market    => $market,
                            submarket => $submarket
                        },
                        ['underlying_symbol']))
                {
                    my $underlying_obj = Finance::Underlying->by_symbol($symbol);
                    my @trade_types    = $self->_get_deriv_trade_types($offerings, $symbol);
                    push @available_trade_types, @trade_types;

                    $product_list{$symbol} //= +{
                        symbol => {
                            name         => $symbol,
                            display_name => $underlying_obj->display_name,
                        },
                        market => {
                            name         => $market,
                            display_name => $market_obj->display_name,
                        },
                        submarket => {
                            name         => $submarket,
                            display_name => $submarket_obj->display_name,
                        },
                        available_trade_types   => [],
                        available_account_types => ['Standard']};

                    $product_list{$symbol}{available_trade_types} = [uniq($product_list{$symbol}{available_trade_types}->@*, @trade_types)];
                }
            }
        }
        $result{name} = $app->display_name if %result;
    }
    $result{available_trade_types} = [uniq(@available_trade_types)];
    $result{available_markets}     = [uniq @available_markets];
    $result{product_list}          = [values %product_list];

    return \%result;
}

=head2 _mt5_listing

Handles MT5 product listing.

=cut

my %account_display_mapping = (
    financial => {
        standard => 'Financial',
        stp      => 'Financial STP',
    },
    gaming => {
        standard => 'Synthetics',
    });

sub _mt5_listing {
    my ($self, $country_code, $app) = @_;

    my $mt_accounts     = $self->countries_instance->mt_account_types_for_country($country_code);
    my $mt5_config      = BOM::Config::MT5->new();
    my $market_registry = Finance::Underlying::Market::Registry->instance;
    my $redis           = BOM::Config::Redis::redis_mt5_user();

    my %mt5_product_list;
    my @mt5_available_markets;
    foreach my $account (grep { $_->{primary} } map { @$_ } values $mt_accounts->%*) {
        # we are only considering real accounts offerings at this point.
        my @groups = $mt5_config->available_groups({
                server_type => 'real',
                company     => $account->{company},
                market_type => $account->{market_type},
                sub_group   => $account->{sub_account_type}});
        next unless @groups;
        foreach my $group (@groups) {
            my $offerings = decode_json($redis->hget('MT5_CONFIG::GROUPS', $group) // '{}');
            # Just the first group should be a good representation of the offerings.
            if ($offerings->{symbols}) {
                # skip group used for exchange rate conversion.
                foreach my $path (grep { $_ !~ /^(?:Conversions|Brokeree)/ } map { $_->{Path} } $offerings->{symbols}->@*) {
                    my @split_tokens = split /\\/, $path;
                    my $submarket    = $split_tokens[0];
                    my $symbol       = $split_tokens[-1];

                    next unless $submarket and $symbol;
                    my $market_obj = $market_registry->get($self->mt5_market_mapper->{$submarket});
                    my ($market_name, $market_display_name) = $market_obj ? ($market_obj->name, $market_obj->display_name) : ('unknown', 'Unknown');
                    $mt5_product_list{$symbol} //= {
                        symbol => {
                            name         => $symbol,
                            display_name => $symbol,
                        },
                        market => {
                            name         => $market_name,
                            display_name => $market_display_name,
                        },
                        submarket => {
                            name         => $submarket,
                            display_name => $submarket,
                        },
                        available_trade_types => ['CFDs'],
                    };
                    push @mt5_available_markets, $market_name;
                    push $mt5_product_list{$symbol}{available_account_types}->@*,
                        $account_display_mapping{$account->{market_type}}{$account->{sub_account_type}};
                }
                last;
            }
        }
    }

    return {
        name                  => $app->display_name,
        available_trade_types => ['CFDs'],
        available_markets     => [uniq(@mt5_available_markets)],
        product_list          => [values %mt5_product_list],
    };
}

=head2 _empty_listing

Empty product listing

=cut

sub _empty_listing {
    my ($self, $country_code, $app) = @_;

    return {
        name                  => $app->display_name,
        available_trade_types => [],
        available_markets     => [],
        product_list          => [],
    };
}

=head2 brand

The brands object. Default to Deriv.

=cut

has brand => (is => 'lazy');

=head2 _build_brand

Builder method for brands.

=cut

sub _build_brand {
    my $self = shift;

    return Brands->new(name => $self->brand_name);
}

=head2 countries_instance

The countries config within a specific brand.

=cut

has countries_instance => (is => 'lazy');

=head2 _build_countries_instance

Builder method for countries within a brand.

=cut

sub _build_countries_instance {
    my $self = shift;

    return $self->brand->countries_instance;
}

## PRIVATE ##

=head2 _get_deriv_trade_types

On the platforms, the name of trade types are grouped under four major branches:
- Accumulators
- Multipliers
- Options
- CFDs

=cut

sub _get_deriv_trade_types {
    my ($self, $offerings, $symbol) = @_;

    my @trade_types;

    my @contract_categories = $offerings->query({underlying_symbol => $symbol}, ['contract_category']);
    push @trade_types, 'Accumulators' if (grep { $_ eq 'accumulator' } @contract_categories);
    push @trade_types, 'Multipliers'  if (grep { $_ eq 'multiplier' } @contract_categories);
    push @trade_types, 'Options'      if (grep { $_ !~ /(?:accumulator|callputspread|multiplier)/ } @contract_categories);
    push @trade_types, 'Spreads'      if (grep { $_ eq 'callputspread' } @contract_categories);

    return @trade_types;
}

1;
