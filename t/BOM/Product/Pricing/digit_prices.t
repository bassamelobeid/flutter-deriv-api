#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
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
        duration    => '10t',
        amount_type => 'payout',
        barrier     => 5,
    };

    my %expectations = (
        DIGITMATCH => {
            bs_prob => 0.10,
            markup  => 0.01,
        },
        DIGITDIFF => {
            bs_prob => 0.90,
            markup  => 0.01,
        },
        DIGITODD => {
            bs_prob => 0.50,
            markup  => 0.01,
        },
        DIGITEVEN => {
            bs_prob => 0.50,
            markup  => 0.01,
        },
        DIGITOVER => {
            bs_prob => 0.40,
            markup  => 0.01,
        },
        DIGITUNDER => {
            bs_prob => 0.50,
            markup  => 0.01,
        },
    );

    foreach my $bt_code (sort keys %expectations) {
        subtest $bt_code => sub {

            my $c = produce_contract({
                    %$params,
                    bet_type => $bt_code,
                    ($bt_code =~ /(?:ODD|EVEN)/ ? (barrier => undef) : ())});

            my $expect = $expectations{$bt_code};

            is $c->pricing_code, $bt_code, 'contract type';

            is $c->pricing_engine_name, 'Pricing::Engine::Digits', 'pricing engine';
            _check_amount($c->theo_probability,  $expect->{bs_prob}, 'bs_prob');
            _check_amount($c->commission_markup, $expect->{markup},  'markup');
        };
    }

    $params->{barrier}  = 9;
    $params->{bet_type} = 'DIGITDIFF';
    my $c = produce_contract($params);
    _check_amount($c->theo_probability,  0.9,  'bs_prob');
    _check_amount($c->commission_markup, 0.01, 'markup not the minmum');
};

subtest 'invalid selections' => sub {

    my $now = time;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_50',
        epoch      => $now,
    });
    my $params = {
        currency     => 'USD',
        amount       => 100,
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_50',
        duration     => '10t',
        amount_type  => 'payout',
    };

    my %cannots = (
        DIGITUNDER => 0,
        DIGITOVER  => 9,
    );

    foreach my $bt_code (sort keys %cannots) {
        subtest $bt_code => sub {
            my $bad_digit = $cannots{$bt_code};
            my $c         = produce_contract({
                %$params,
                bet_type => $bt_code,
                barrier  => $bad_digit
            });
            cmp_ok $c->ask_price, '>=', 0, 'We can compute a price for ' . $bt_code . ' with digit of ' . $bad_digit;
            ok !$c->is_valid_to_buy, '... but it is not valid to sell';
            like($c->primary_validation_error->message, qr/No winning digits/, '... and among the reasons is that the digit cannot win.');

        };

    }
};

sub _check_amount {
    my ($which, $amount, $desc) = @_;

    cmp_ok(roundcommon(1e-4, $which->amount), '==', roundcommon(1e-4, $amount), $desc . ' rounds to the correct number');
}

1;
