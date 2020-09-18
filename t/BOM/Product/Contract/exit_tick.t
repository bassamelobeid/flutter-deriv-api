#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Product::Contract;

subtest 'Exit tick for tick trades' => sub {
    my $mock = Test::MockModule->new('BOM::Product::Contract');

    $mock->mock(pricing_new           => 0);
    $mock->mock(underlying            => 'USD');
    $mock->mock(tick_expiry           => 1);
    $mock->mock(ticks_to_expiry       => 1);
    $mock->mock(ticks_for_tick_expiry => []);

    my $exit_tick = BOM::Product::Contract->_build_exit_tick();
    is $exit_tick, undef, 'No exit tick if there are not enogh ticks';

    my $cur_time = time;
    $mock->mock(date_pricing          => Date::Utility->new($cur_time));
    $mock->mock(ticks_for_tick_expiry => [Date::Utility->new($cur_time + 1)]);

    $exit_tick = BOM::Product::Contract->_build_exit_tick();
    is $exit_tick, undef, 'No exit tick if tick come from future';

    $mock->mock(ticks_for_tick_expiry => [Date::Utility->new($cur_time)]);
    $mock->mock(date_expiry           => sub { });
    $mock->mock(is_valid_exit_tick    => sub { });
    $mock->mock(entry_tick            => 0);

    $exit_tick = BOM::Product::Contract->_build_exit_tick();
    ok $exit_tick, 'Got exit tick';
    is $exit_tick->epoch, $cur_time, 'Exit tick is correct';
};

done_testing();
