#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use JSON::MaybeXS;
use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Cache::RedisDB;
use BOM::Product::ContractFactory qw(produce_contract);

my $json = JSON::MaybeXS->new;

my $now    = Date::Utility->new('2017-10-10');
my $expiry = $now->plus_time_interval('15m');
my $args   = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    barrier      => 'S0P',
    date_start   => $now,
    date_pricing => $now,
    date_expiry  => $expiry,
    currency     => 'USD',
    payout       => 10
};
subtest 'no audit details' => sub {
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->exit_tick,  'no exit tick';
    ok !%{$c->audit_details}, 'no audit details';
};

subtest 'when there is tick at start & expiry' => sub {
    my @before =
        map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2 .. 2);
    my @after = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2 .. 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before, @after);
    my $c = produce_contract({%$args, date_pricing => $expiry});
    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"flag":"highlight_time","epoch":"1507593600","name":["Start Time"],"tick":"100","tick_display_value":"100.000"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"}],"contract_end":[{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507594499","tick":"99.999","tick_display_value":"99.999"},{"flag":"highlight_tick","epoch":"1507594500","name":["[_1] and [_2]","End Time","Exit Spot"],"tick":"100","tick_display_value":"100.000"},{"epoch":"1507594501","tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507594502","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'there are ticks with same quote' => sub {
    my @before =
        map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2 .. 2);
    my @after = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2 .. 2);
    $before[3][0] = $before[2][0];
    $after[3][0]  = $after[2][0];
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before, @after);
    my $c = produce_contract({%$args, date_pricing => $expiry});
    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"flag":"highlight_time","epoch":"1507593600","name":["Start Time"],"tick":"100","tick_display_value":"100.000"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100","tick_display_value":"100.000"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"}],"contract_end":[{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507594499","tick":"99.999","tick_display_value":"99.999"},{"flag":"highlight_tick","epoch":"1507594500","name":["[_1] and [_2]","End Time","Exit Spot"],"tick":"100","tick_display_value":"100.000"},{"epoch":"1507594501","tick":"100","tick_display_value":"100.000"},{"epoch":"1507594502","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'no tick at start & expiry' => sub {
    my @before =
        map { [100, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    my @after = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before, @after);
    my $c = produce_contract({%$args, date_pricing => $expiry});

    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"100","tick_display_value":"100.000"},{"epoch":"1507593599","tick":"100","tick_display_value":"100.000"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100","tick_display_value":"100.000"},{"epoch":"1507593602","tick":"100","tick_display_value":"100.000"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"}],"contract_end":[{"epoch":"1507593602","tick":"100","tick_display_value":"100.000"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"},{"flag":"highlight_tick","epoch":"1507594499","name":["Exit Spot"],"tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507594500","name":["End Time"],"flag":"highlight_time"},{"epoch":"1507594501","tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507594502","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'expiry daily' => sub {
    my $expiry = $now->truncate_to_day->plus_time_interval('23h59m59s');
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    my @after  = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before, @after);
    my $c = produce_contract({
        %$args,
        date_pricing => $expiry,
        date_expiry  => $expiry
    });

    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    ok $c->expiry_daily,       'expiry daily contract';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"},{"epoch":"1507679997","tick":"99.998","tick_display_value":"99.998"}],"contract_end":[{"epoch":"1507679999","name":["Closing Spot"],"flag":"highlight_tick","tick":"99.999","tick_display_value":"99.999"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'sold after start' => sub {
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before);
    my $c = produce_contract({
        %$args,
        is_sold     => 1,
        pricing_new => 0
    });
    ok $c->is_sold, 'is sold';
    ok !$c->is_expired, 'no expired';
    ok $c->entry_tick, 'entry tick is defined';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'forward starting sold after start' => sub {
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before);
    my $c = produce_contract({
        %$args,
        is_sold                    => 1,
        pricing_new                => 0,
        starts_as_forward_starting => 1
    });
    ok $c->is_sold, 'is sold';
    ok !$c->is_expired, 'no expired';
    ok $c->entry_tick, 'entry tick is defined';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"flag":"highlight_tick","epoch":"1507593599","name":["Entry Spot"],"tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"epoch":"1507593601","tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'path dependent hit' => sub {
    $args->{barrier}      = 100.002;
    $args->{bet_type}     = 'NOTOUCH';
    $args->{date_pricing} = $now->epoch + 2;
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before);
    my $c = produce_contract($args);
    ok $c->is_expired, 'is expired';
    ok $c->hit_tick,   'hit tick is defined';
    ok !$c->is_after_settlement, 'before settlement time';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"}],"contract_end":[{"epoch":"1507593602","name":["Exit Spot"],"flag":"highlight_tick","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

subtest 'path dependent expires unhit' => sub {
    $args->{barrier}      = 100.012;
    $args->{bet_type}     = 'NOTOUCH';
    $args->{date_pricing} = $args->{date_expiry};
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_,    'frxUSDJPY'] } (-2, -1, 1, 2);
    my @after  = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@before, @after);
    my $c = produce_contract($args);
    ok $c->is_expired, 'is expired';
    ok !$c->hit_tick, 'hit tick is defined';
    ok $c->is_after_settlement, 'before settlement time';
    my $expected = $json->decode(
        '{"contract_start":[{"epoch":"1507593598","tick":"99.998","tick_display_value":"99.998"},{"epoch":"1507593599","tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507593600","name":["Start Time"],"flag":"highlight_time"},{"flag":"highlight_tick","epoch":"1507593601","name":["Entry Spot"],"tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"}],"contract_end":[{"epoch":"1507593602","tick":"100.002","tick_display_value":"100.002"},{"epoch":"1507594498","tick":"99.998","tick_display_value":"99.998"},{"flag":"highlight_tick","epoch":"1507594499","name":["Exit Spot"],"tick":"99.999","tick_display_value":"99.999"},{"epoch":"1507594500","name":["End Time"],"flag":"highlight_time"},{"epoch":"1507594501","tick":"100.001","tick_display_value":"100.001"},{"epoch":"1507594502","tick":"100.002","tick_display_value":"100.002"}]}'
    );
    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

done_testing();
