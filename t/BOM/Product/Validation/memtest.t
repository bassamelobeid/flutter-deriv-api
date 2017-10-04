#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Test::Memory::Cycle;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Offerings qw(get_offerings_with_filter);
use Date::Utility;
use Finance::Asset;
use LandingCompany::Offerings qw(reinitialise_offerings);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Market::DataDecimate;
use Cache::RedisDB;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

note('mocking ticks to prevent warnings.');
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock('get', sub {[map {{epoch => $_, decimate_epoch => $_, quote => 100 + 0.005*$_}} (0..80)]});
$mocked->mock(
    'decimate_cache_get',
    sub {
        [map { {quote => 100, symbol => 'frxUSDJPY', epoch => $_, decimate_epoch => $_, agg_epoch => $_} } (0 .. 10)];
    });

my $mocked2 = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked2->mock(
    'data_cache_get',
    sub {
        [map { {quote => 100, symbol => 'frxUSDJPY', decimate_epoch => $_} } (0 .. 10)];
    });

my $now            = Date::Utility->new;
my $offerings_cfg  = BOM::Platform::Runtime->instance->get_offerings_config;
my @contract_types = get_offerings_with_filter($offerings_cfg, 'contract_type');
my @submarkets     = get_offerings_with_filter($offerings_cfg, 'submarket');
my @underlyings =
    map { create_underlying($_) } map { (get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {submarket => $_}))[0] } @submarkets;

# just do for everything
my $all                     = Finance::Asset->all_parameters;
my @market_data_underlyings = map { create_underlying({symbol => $_, for_date => $now}) } keys %$all;
my @exchanges               = map { Finance::Asset->get_parameters_for($_->symbol)->{exchange_name} } @market_data_underlyings;
my %known_surfaces          = map { $_ => 1 } qw(moneyness delta);
my %volsurfaces =
    map { $_->symbol => 'volsurface_' . $_->volatility_surface_type } grep { $known_surfaces{$_->volatility_surface_type} } @market_data_underlyings;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_->symbol,
        recorded_date => $now
    }) for grep { $_->symbol !~ /frx/ } @market_data_underlyings;
my @currencies =
    map { $_->market->name =~ /(forex|commodities)/ ? ($_->asset_symbol, $_->quoted_currency_symbol) : ($_->quoted_currency_symbol) } @underlyings;

my @payout_curr = qw(USD GBP EUR AUD);
for (@currencies, @payout_curr, 'AUD-JPY', 'CAD-AUD') {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now
        });
}
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        symbol        => 'indices',
        correlations  => \%correlations,
        recorded_date => Date::Utility->new->minus_time_interval('1d'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

        my $redis     = Cache::RedisDB->redis;
        my $undec_key = "DECIMATE_$u_symbol" . "_31m_FULL";
        my $encoder   = Sereal::Encoder->new({
            canonical => 1,
        });
        my %defaults = (
            symbol => $u_symbol,
            epoch  => $now->epoch,
            quote  => 100,
            bid    => 100,
            ask    => 100,
            count  => 1,
        );
        $redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

        foreach my $type (@contract_types) {
            next if $type =~ /^(LBFIXEDCALL|LBFIXEDPUT|LBFLOATCALL|LBFLOATPUT|LBHIGHLOW)/;

            foreach my $start_type (
                get_offerings_with_filter(
                    $offerings_cfg,
                    'start_type',
                    {
                        contract_type     => $type,
                        underlying_symbol => $u_symbol
                    }))
            {
                foreach my $expiry_type (
                    get_offerings_with_filter(
                        $offerings_cfg,
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
