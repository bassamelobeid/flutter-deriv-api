#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_50',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'R_50',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                event_name   => 'FOMC',
            }]});

subtest 'prices' => sub {

    my $params = {
        contract_type => 'TICKHIGH',
        currency      => 'USD',
        amount        => 100,
        date_start    => time,
        underlying    => 'R_50',
        duration      => '10t',
        amount_type   => 'payout',
        selected_tick => 3,
    };

    my %expectations = (
        TICKHIGH => {
            bs_prob => 0.141,
            markup  => 0.012,
        },
        TICKLOW => {
            bs_prob => 0.141,
            markup  => 0.012,
        },
    );

    # Test each code
    foreach my $bt_code (sort keys %expectations) {
        subtest $bt_code => sub {
            my $c = produce_contract({%$params, bet_type => $bt_code});
            my $expect = $expectations{$bt_code};

            is $c->pricing_code, $bt_code, 'contract type';

            is $c->pricing_engine_name, 'Pricing::Engine::HighLow::Ticks', 'pricing engine';
            _check_amount($c->theo_probability,  $expect->{bs_prob}, 'bs_prob');
            _check_amount($c->commission_markup, $expect->{markup},  'markup');
        };
    }

    $params->{bet_type} = 'TICKHIGH';
    my $c = produce_contract($params);
    _check_amount($c->theo_probability,  0.141, 'bs_prob');
    _check_amount($c->commission_markup, 0.012, 'markup not the minimum');
};

sub _check_amount {
    my ($which, $amount, $desc) = @_;

    cmp_ok(roundcommon(1e-4, $which->amount), '==', roundcommon(1e-4, $amount), $desc . ' rounds to the correct number');
}

1;
