#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMD qw(:init);

use Test::More tests => 2;
use Test::NoWarnings;
use Test::Exception;
use Test::Memory::Cycle;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use Date::Utility;
use Finance::Asset;
use BOM::Market::Underlying;

my $now            = Date::Utility->new;
my @contract_types = get_offerings_with_filter('contract_type');
my @submarkets     = get_offerings_with_filter('submarket');
my @underlyings = map { BOM::Market::Underlying->new($_) } map { (get_offerings_with_filter('underlying_symbol', {submarket => $_}))[0] } @submarkets;

# just do for everything
my $all                     = Finance::Asset->all_parameters;
my @market_data_underlyings = map { BOM::Market::Underlying->new($_) } keys %$all;
my @exchanges               = map { Finance::Asset->get_parameters_for($_->symbol)->{exchange_name} } @market_data_underlyings;
my %known_surfaces = map {$_ => 1} qw(moneyness delta);
my %volsurfaces = map { $_->symbol => 'volsurface_' . $_->volatility_surface_type } grep { $known_surfaces{$_->volatility_surface_type} } @market_data_underlyings;
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'index',
    {
        symbol        => $_->symbol,
        recorded_date => $now
    }) for grep { $_->symbol !~ /frx/ } @market_data_underlyings;
my @currencies =
    map { $_->market->name =~ /(forex|commodities)/ ? ($_->asset_symbol, $_->quoted_currency_symbol) : ($_->quoted_currency_symbol) } @underlyings;

for (@currencies, 'AUD-JPY', 'AUD-CAD', 'JPY-AUD', 'CAD-AUD') {
    BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now
        });
}
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    $volsurfaces{$_},
    {
        symbol        => $_,
        recorded_date => $now
    }) for keys %volsurfaces;
my %correlations = map {
    $_->symbol => {
        GBP => {
            '3M'  => 0.356,
            '6M'  => 0.336,
            '9M'  => 0.32,
            '12M' => 0.307,
        },
        USD => {
            '3M'  => 0.356,
            '6M'  => 0.336,
            '9M'  => 0.32,
            '12M' => 0.307,
        },
        AUD => {
            '3M'  => 0.356,
            '6M'  => 0.336,
            '9M'  => 0.32,
            '12M' => 0.307,
        },
        EUR => {
            '3M'  => 0.356,
            '6M'  => 0.336,
            '9M'  => 0.32,
            '12M' => 0.307,
        },
        }
    } grep {
    $_->symbol !~ /frx/
    } @market_data_underlyings;

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'correlation_matrix',
    {
        symbol       => 'indices',
        correlations => \%correlations,
        for_date     => Date::Utility->new->minus_time_interval("30m"),
    });

my %start_type = (
    spot    => $now,
    forward => $now->plus_time_interval('15m'),
);
my %expiry_type = (
    daily    => '7d',
    intraday => '5h',
    tick     => '10t',
);

#Cycle test will complain because of data types it cannot handle (Redis's Socket has these data types)
#So we just ignore those complaints here
$SIG{__WARN__} = sub { my $w = shift; return if $w =~ /^Unhandled type: GLOB/; die $w; };

sub _get_barrier {
    my $type = shift;

    if ($type =~ /(EXPIRYMISS|EXPIRYRANGE|RANGE|UPORDOWN)/) {
        return {
            daily => [{
                    high_barrier => 120,
                    low_barrier  => 90
                }
            ],
            intraday => [{
                    high_barrier => 'S20P',
                    low_barrier  => 'S-10P'
                }
            ],
        };
    } elsif ($type =~ /(ONETOUCH|NOTOUCH)/) {
        return {
            daily    => [{barrier => 120}],
            intraday => [{barrier => 'S20P'}],
        };
    } elsif ($type =~ /(CALL|PUT)/) {
        return {
            daily    => [{barrier => 120},    {barrier => 'S0P'}],
            intraday => [{barrier => 'S20P'}, {barrier => 'S0P'}],
            tick     => [{barrier => 'S0P'}],
        };
    } elsif ($type =~ /(ASIAN|SPREAD)/) {
        return {tick => [{}]};
    } elsif ($type =~ /DIGIT/) {
        return {tick => [{barrier => 5}]};    # should work for all DIGITS
    }
}

subtest 'memory cycle test' => sub {
    foreach my $underlying (@underlyings) {
        my $u_symbol     = $underlying->symbol;
        my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $u_symbol,
            epoch      => $now->epoch,
            quote      => 100,
        });
        foreach my $type (@contract_types) {
            foreach my $start_type (
                get_offerings_with_filter(
                    'start_type',
                    {
                        contract_type     => $type,
                        underlying_symbol => $u_symbol
                    }))
            {
                foreach my $expiry_type (
                    get_offerings_with_filter(
                        'expiry_type',
                        {
                            contract_type     => $type,
                            underlying_symbol => $u_symbol,
                            start_type        => $start_type
                        }))
                {
                    my $barrier_ref = _get_barrier($type);
                    my $barriers;
                    $barriers = $barrier_ref->{$expiry_type} if keys %$barrier_ref;
                    foreach my $barrier (@$barriers) {
                        foreach my $currency (qw(USD GBP AUD EUR)) {
                            lives_ok {
                                my $c = produce_contract({
                                        bet_type     => $type,
                                        underlying   => $u_symbol,
                                        date_start   => $start_type{$start_type},
                                        date_pricing => $start_type{$start_type},
                                        duration     => $expiry_type{$expiry_type},
                                        currency     => $currency,
                                        payout       => 100,
                                        current_tick => $current_tick,
                                        %{$barrier}});
                                ok $c->ask_probability, 'ask_probability';
                                memory_cycle_ok($c);
                            }
                            "lives through mem test [contract_type[$type] underlying_symbol[$u_symbol] start_type[$start_type] expiry_type[$expiry_type]";
                        }
                    }
                }
            }
        }
    }
}
