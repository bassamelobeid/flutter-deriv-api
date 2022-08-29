#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData               qw(create_underlying);
use BOM::Config::QuantsConfig;
use Postgres::FeedDB::Spot::Tick;

my $now = Date::Utility->new('2020-06-10');
my $qc  = BOM::Config::QuantsConfig->new(
    chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    recorded_date    => $now,
);

subtest 'create custom deal cancellation config' => sub {
    my $custom_dc_config = {
        underlying_symbol    => 'R_100',
        landing_companies    => 'virtual',
        dc_types             => '5m,10m,15m',
        start_datetime_limit => $now->date . "T" . $now->time_hhmmss,
        end_datetime_limit   => $now->date . "T" . $now->plus_time_interval('1h')->time_hhmmss,
        dc_comment           => "test create"
    };

    my $key  = "deal_cancellation";
    my $name = $custom_dc_config->{underlying_symbol} . "_" . $custom_dc_config->{landing_companies};
    $custom_dc_config->{id} = $name;
    my $dc_config->{"$name"} = $custom_dc_config;
    my $result = $qc->save_config($key, $dc_config);

    ok $result, "Custom deal cancellation config created Successfully";
};

subtest 'client able to buy mutiplier contract' => sub {
    my $underlying = create_underlying('R_100');

    my $tick_params = {
        symbol => 'R_100',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $current_tick = Postgres::FeedDB::Spot::Tick->new($tick_params);

    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'MULTUP',
        currency     => 'USD',
        multiplier   => 100,
        amount       => 100,
        date_start   => $now->epoch,
        date_pricing => $now->epoch,
        amount_type  => 'stake',
        current_tick => $current_tick,
        cancellation => '5m',
    });
    ok $contract->is_valid_to_buy, 'Valid for purchase';
};

subtest 'client cannot buy mutiplier contract with deal cancellation disabled' => sub {
    my $underlying = create_underlying('R_100');

    my $tick_params = {
        symbol => 'R_100',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $current_tick = Postgres::FeedDB::Spot::Tick->new($tick_params);

    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'MULTUP',
        currency     => 'USD',
        multiplier   => 100,
        amount       => 100,
        date_start   => $now->epoch,
        date_pricing => $now->epoch,
        amount_type  => 'stake',
        current_tick => $current_tick,
        cancellation => '1h',
    });
    ok $contract->is_valid_to_buy eq 0, 'Not able to buy';
};

subtest 'delete custom deal cancellation config' => sub {
    my $custom_dc_config = {
        underlying_symbol => 'R_100',
        landing_companies => 'virtual',
    };

    my $key    = "deal_cancellation";
    my $name   = $custom_dc_config->{underlying_symbol} . "_" . $custom_dc_config->{landing_companies};
    my $result = $qc->delete_config($key, $name);

    ok $result, "Custom deal cancellation config deleted Successfully";
};

done_testing();
