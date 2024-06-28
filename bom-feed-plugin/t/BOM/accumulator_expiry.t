#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 11;
use Test::Warnings;
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $start_time = Date::Utility->new;

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [100, $start_time->epoch,     'R_75'],
    [101, $start_time->epoch + 1, 'R_75'],
    [102, $start_time->epoch + 2, 'R_75'],
    [103, $start_time->epoch + 3, 'R_75']);

use BOM::FeedPlugin::Plugin::AccumulatorExpiry;
use BOM::FeedPlugin::Client;

my $mocked_method = Test::MockModule->new('BOM::FeedPlugin::Plugin::AccumulatorExpiry');
$mocked_method->mock(
    'last_stored_tick_barrier_status',
    sub {
        return {
            "R_75::growth_rate_0.02" => {
                "high_barrier" => 9874.74313034621,
                "low_barrier"  => 9866.2664696538,
                "tick_epoch"   => $start_time->epoch
            }};
    });
$mocked_method->mock('redis', sub { return });

my $tick = {
    "epoch"  => $start_time->epoch + 3,
    "symbol" => "R_75"
};

my $out = BOM::FeedPlugin::Plugin::AccumulatorExpiry->_missed_ticks_on_restart($tick, 'R_75', 'R_75::growth_rate_0.02');
is scalar @$out, 3, 'Two tick is returned';

while (my ($index, $tick) = each @$out) {
    $index += 1;    # array starts at 0 unfortunately
    is $tick->{symbol}, 'R_75',                      "Symbol at index $index is R_75";
    is $tick->{epoch},  $start_time->epoch + $index, "Epoch at index $index is " . ($start_time->epoch + $index);
    is $tick->{quote},  100 + $index,                "Symbol at index $index is " . (100 + $index);
}

done_testing;
