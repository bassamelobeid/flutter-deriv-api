#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use List::Util ();
use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Test::Memory::Cycle;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Product::ContractFactory              qw(produce_contract);
use LandingCompany::Registry;
use Date::Utility;
use Finance::Underlying;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Market::DataDecimate;
use Cache::RedisDB;
use Postgres::FeedDB::Spot::Tick;

my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
$redis_exchangerates->hmset(
    'exchange_rates::EUR_USD',
    quote => 1.00080,
    epoch => time
);
$redis_exchangerates->hmset(
    'exchange_rates::GBP_USD',
    quote => 1.14239,
    epoch => time
);
$redis_exchangerates->hmset(
    'exchange_rates::AUD_USD',
    quote => 0.67414,
    epoch => time
);

my $mock_calendar = Test::MockModule->new('Finance::Calendar');
$mock_calendar->mock(is_open_at => sub { 1 });

note('always use market data');
my $u_c = Test::MockModule->new('Quant::Framework::Underlying');
$u_c->mock('uses_implied_rate', sub { 0 });

note('mocking ticks to prevent warnings.');
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
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

my $offerings_obj = LandingCompany::Registry->by_name('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
my $now           = Date::Utility->new;
my @contract_types =
    map { ($offerings_obj->query({contract_category => $_}, ['contract_type']))[0] } $offerings_obj->values_for_key('contract_category');
my @submarkets = $offerings_obj->values_for_key('submarket');

# Because this test taking too long, So we run parallel jobs in CI, each job run part of the test.
# We divided @submarkets into several parts, and only loop one part in each job.

@submarkets = run_test_sub_group($ENV{run_test_sub_group}, [@submarkets]) if $ENV{run_test_sub_group};

my @underlyings =
    map { create_underlying($_) } map { ($offerings_obj->query({submarket => $_}, ['underlying_symbol']))[0] } @submarkets;

# just do for everything
my @market_data_underlyings = map { create_underlying({symbol => $_, for_date => $now}) } Finance::Underlying->symbols;
my @exchanges               = map { Finance::Underlying->by_symbol($_->symbol)->exchange_name } @market_data_underlyings;
my %known_surfaces          = map { $_ => 1 } qw(moneyness delta);
my %volsurfaces =
    map { $_->symbol => 'volsurface_' . $_->volatility_surface_type } grep { $known_surfaces{$_->volatility_surface_type} } @market_data_underlyings;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_->symbol,
        recorded_date => $now
    }) for grep { $_->symbol !~ /frx/ } @market_data_underlyings;
my @currencies = List::Util::uniqstr grep { !!$_ }    # filter out duplicated or empty ('') currency symbols
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
        recorded_date => $now,
        spot_tick     => Postgres::FeedDB::Spot::Tick->new({epoch => $now->epoch, quote => '1.00'})}) for keys %volsurfaces;
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
} grep { $_->symbol !~ /frx/ } @market_data_underlyings;

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
    } elsif ($type =~ /(CALLSPREAD|PUTSPREAD)/) {
        return {
            intraday => [{barrier_range => 'tight'}, {barrier_range => 'middle'}, {barrier_range => 'wide'}],
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
    } elsif ($type =~ /DIGIT(?:MATCH|DIFF|OVER|UNDER)/) {
        return {tick => [{barrier => 5}]};    # should work for all DIGITS
    } else {
        return {tick => [{}]};
    }
}

=head2 run_test_sub_group

Usage:
run_test_sub_group('2/3',$arrayref)
Divide the array into 3 parts, and return the 2nd part of the array

=cut

sub run_test_sub_group {
    my ($param, $arrayref) = @_;

    die "group param wrong: $param" unless $param =~ /^\d+\/\d+$/;

    my ($group_number, $division) = split('/', $param);

    note("Running the Number $group_number of $division groups");

    my @array = sort @$arrayref;
    die "group param wrong: $param"
        if ($division > @array or $group_number > $division or $group_number < 1);

    my $array_length = scalar @array;
    my $part_size    = int($array_length / $division);
    $part_size += 1 if $array_length % $division;

    # Calculate the starting and ending indices for the specified part
    my $start_index = ($group_number - 1) * $part_size;
    my $end_index   = $group_number * $part_size - 1;
    $end_index = $#array if $end_index > $#array;

    return @array[$start_index .. $end_index];
}

subtest 'test_sub_group' => sub {
    my $array = [1, 2, 3, 4, 5];
    is_deeply [run_test_sub_group('1/3', $array)], [1, 2], 'group 1/3';
    is_deeply [run_test_sub_group('2/3', $array)], [3, 4], 'group 2/3';
    is_deeply [run_test_sub_group('3/3', $array)], [5],    'group 3/3';
    is_deeply [run_test_sub_group('5/5', $array)], [5],    'group 5/5';

    is_deeply [run_test_sub_group('1/1', [0])], [0], 'group 1/1';

    $array = [qw/d b c e a/];
    is_deeply [run_test_sub_group('1/2', $array)], ['a', 'b', 'c'], 'group 1/2';
    is_deeply [run_test_sub_group('2/2', $array)], ['d', 'e'], 'group 2/2';

    throws_ok { run_test_sub_group('a/2',   $array) } qr/group param wrong/, 'param wrong: a/2';
    throws_ok { run_test_sub_group('4.3/3', $array) } qr/group param wrong/, 'param wrong: 4.3/3';
    throws_ok { run_test_sub_group('0/2',   $array) } qr/group param wrong/, 'param wrong: 0/2';
    throws_ok { run_test_sub_group('3/2',   $array) } qr/group param wrong/, 'param wrong: 3/2';
    throws_ok { run_test_sub_group('1/10',  $array) } qr/group param wrong/, 'param wrong: 1/10';

};

subtest 'memory cycle test' => sub {
    foreach my $underlying (@underlyings) {
        my $u_symbol = $underlying->symbol;
        diag("underlying symbol $u_symbol");
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
            next
                if $type =~
                /^(LBFIXEDCALL|LBFIXEDPUT|LBFLOATCALL|LBFLOATPUT|LBHIGHLOW|TICKHIGH|TICKLOW|RUNHIGH|RUNLOW|MULTUP|MULTDOWN|VANILLALONGCALL|VANILLALONGPUT|TURBOSLONG|TURBOSSHORT)/;

            foreach my $start_type (
                $offerings_obj->query({
                        contract_type     => $type,
                        underlying_symbol => $u_symbol
                    },
                    ['start_type']))
            {
                foreach my $expiry_type (
                    $offerings_obj->query({
                            contract_type     => $type,
                            underlying_symbol => $u_symbol,
                            start_type        => $start_type
                        },
                        ['expiry_type']))
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
                                if ($c->is_binary) {
                                    ok $c->ask_probability, 'ask_probability';
                                } else {
                                    ok $c->ask_price, 'ask price';
                                }
                                memory_cycle_ok($c);
                            }
                            "lives through mem test [contract_type[$type] underlying_symbol[$u_symbol] start_type[$start_type] expiry_type[$expiry_type] currency[$currency]]";
                        }
                    }
                }
            }
        }
    }
};

