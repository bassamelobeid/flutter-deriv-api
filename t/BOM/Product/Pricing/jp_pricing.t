#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Offerings qw(get_offerings_flyby);
use BOM::Product::Contract::Finder::Japan qw(available_contracts_for_symbol);
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use Date::Utility;
use Quant::Framework::Underlying;
use Test::MockModule;

initialize_realtime_ticks_db();

my $fb      = get_offerings_flyby({}, 'japan');
my @symbols = $fb->values_for_key('underlying_symbol');
my $now     = Date::Utility->new;

# skipped setting up implied rate data
my $mock = Test::MockModule->new('Quant::Framework::Underlying');
$mock->mock('uses_implied_rate', sub {0});

foreach my $s (@symbols) {
    _setup_market_data($s, 'JPY');
    generate_trading_periods($s, $now);
    my $offerings = available_contracts_for_symbol({
            symbol          => $s,
            landing_company => 'japan'
        })->{available};
    foreach my $o (@$offerings) {
        my $start = $o->{trading_period}->{date_start}->{epoch};
        _create_tick($s, 100, $start);
        my $parameters = {
            bet_type        => $o->{contract_type},
            underlying      => $o->{underlying_symbol},
            date_start      => $start,
            date_pricing    => $start,
            date_expiry     => $o->{trading_period}->{date_expiry}->{epoch},
            currency        => 'JPY',
            landing_company => 'japan',
            payout          => 1000

        };
        foreach my $barrier (@{$o->{available_barriers}}) {
            if (ref $barrier eq 'ARRAY') {
                $parameters->{high_barrier} = $barrier->[1];
                $parameters->{low_barrier} = $barrier->[0];
            } else {
                $parameters->{barrier} = $barrier;
            }
            $DB::single=1;
            my $c   = produce_contract($parameters);
            my $ask = $c->ask_price;
            my $bid = $c->payout - $c->opposite_contract->ask_price;
            is $ask + $bid, $c->payout, 'ask & bid matches ';
        }
    }
}

sub _create_tick {
    my ($symbol, $quote, $epoch) = @_;

    return BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        quote      => $quote,
        epoch      => $epoch,
    });
}

sub _setup_market_data {
    my ($symbol, $payout_currency) = @_;

    my $u = Quant::Framework::Underlying->new($symbol);
    my $one_year_ago = $now->minus_time_interval('365d');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $one_year_ago,
        }) for ($u->symbol, 'frx' . $u->quoted_currency_symbol . $payout_currency, 'frx' . $u->asset_symbol . $payout_currency);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $one_year_ago
        }) for ($u->quoted_currency_symbol, $u->asset_symbol);

    return;
}
