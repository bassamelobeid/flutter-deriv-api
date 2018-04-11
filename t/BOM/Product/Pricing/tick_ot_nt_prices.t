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
        currency    => 'USD',
        amount      => 100,
        date_start  => time,
        underlying  => 'R_50',
        tick_expiry => 1,
        tick_count  => 5,
        amount_type => 'payout',
        barrier     => '-0.3054',
    };

    my %expectations = (
        ONETOUCH => {
            bs_prob => 0.1861,
            markup  => 0.023 + 0.02,
        },
        NOTOUCH => {
            bs_prob => 0.8139,
            markup  => 0.023 + 0.02,
        },
    );

    foreach my $bt_code (sort keys %expectations) {
        subtest $bt_code => sub {

            my $c = produce_contract({%$params, bet_type => $bt_code});

            my $expect = $expectations{$bt_code};
            is $c->pricing_code, $bt_code, 'contract type';
            $c->shortcode;
            $c->pricing_spot;
            is $c->pricing_spot, '963.3054', 'pricing spot';
            is $c->pricing_engine_name, 'Pricing::Engine::BlackScholes', 'pricing engine';
            _check_amount($c->theo_probability,  $expect->{bs_prob}, 'bs_prob');
            _check_amount($c->commission_markup, $expect->{markup},  'markup');
        };
    }

};

sub _check_amount {
    my ($which, $amount, $desc) = @_;

    cmp_ok(roundcommon(1e-4, $which->amount), '==', roundcommon(1e-4, $amount), $desc . ' rounds to the correct number');
}

1;
