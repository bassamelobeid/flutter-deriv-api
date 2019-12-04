#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

my $now          = Date::Utility->new;
my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    quote      => 100,
    epoch      => $now->epoch,
});

subtest 'make_similar_contract' => sub {
    my $args = {
        'currency'    => 'USD',
        'underlying'  => 'R_100',
        'bet_type'    => 'PUT',
        'amount'      => '0.35',
        'amount_type' => 'stake',
        'barrier'     => 'S0P',
        'duration'    => '2t',
        current_tick  => $current_tick,
    };
    my $c = produce_contract($args);
    my $new = make_similar_contract($c);
    is $c->ask_price, $new->ask_price, 'ask price is the same after make_similar_contract';

    $new = make_similar_contract($c, {amount_type => 'payout', amount => $c->payout});
    is $c->ask_price, $new->ask_price, 'ask price is the same after make_similar_contract';
};

done_testing();
