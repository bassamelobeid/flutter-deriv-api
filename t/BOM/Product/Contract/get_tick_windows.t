#!/usr/bin/perl

use Test::More;
use Test::Exception;

use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;
use Date::Utility;

my $mocked_economic_events = Test::MockModule->new('Volatility::EconomicEvents');
my $now                    = Date::Utility->new->truncate_to_day;
my $period;

sub get_contract {
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    });
    $period //= {
        from => $c->effective_start->minus_time_interval('20m'),
        to   => $c->effective_start
    };
    return $c;
}

subtest 'no events' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock('categorized_events', sub { [] });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 1, 'only one window';
    is $windows->[0][0], $now->minus_time_interval('20m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
};

subtest 'event spans contract pricing time' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('5m')->epoch,
                    duration      => 600,
                    magnitude     => 10,
                }];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 1, 'only one window';
    is $windows->[0][0], $now->minus_time_interval('25m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->minus_time_interval('5m')->epoch,  'correct end of period';
};

subtest 'one event which does not span the contract pricing time - so two windows' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('10m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                }];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 2, 'two windows';
    is $windows->[0][0], $now->minus_time_interval('5m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
    is $windows->[1][0], $now->minus_time_interval('25m')->epoch, 'correct start of period';
    is $windows->[1][1], $now->minus_time_interval('10m')->epoch, 'correct end of period';
};

subtest 'two overlapping events - two windows' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('10m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                },
                {
                    release_epoch => $now->minus_time_interval('15m')->epoch,
                    duration      => 600,
                    magnitude     => 10,
                },
            ];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 2, 'two windows';
    is $windows->[0][0], $now->minus_time_interval('5m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
    is $windows->[1][0], $now->minus_time_interval('30m')->epoch, 'correct start of period';
    is $windows->[1][1], $now->minus_time_interval('15m')->epoch, 'correct end of period';
};

subtest 'two overlapping events, second event\'s duration cross first event - two windows' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('10m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                },
                {
                    release_epoch => $now->minus_time_interval('15m')->epoch,
                    duration      => 660,
                    magnitude     => 10,
                },
            ];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 2, 'two windows';
    is $windows->[0][0], $now->minus_time_interval('4m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
    is $windows->[1][0], $now->minus_time_interval('31m')->epoch, 'correct start of period';
    is $windows->[1][1], $now->minus_time_interval('15m')->epoch, 'correct end of period';
};

subtest '3 events with two overlapping events - three windows' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('10m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                },
                {
                    release_epoch => $now->minus_time_interval('15m')->epoch,
                    duration      => 600,
                    magnitude     => 10,
                },
                {
                    release_epoch => $now->minus_time_interval('25m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                },
            ];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 3, 'three windows';
    is $windows->[0][0], $now->minus_time_interval('5m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
    is $windows->[1][0], $now->minus_time_interval('20m')->epoch, 'correct start of period';
    is $windows->[1][1], $now->minus_time_interval('15m')->epoch, 'correct end of period';
    is $windows->[2][0], $now->minus_time_interval('35m')->epoch, 'correct start of period';
    is $windows->[2][1], $now->minus_time_interval('25m')->epoch, 'correct end of period';
};

subtest 'indentical release date with different duration impact - two windows' => sub {
    my $c = get_contract();
    $mocked_economic_events->mock(
        'categorize_events',
        sub {
            [{
                    release_epoch => $now->minus_time_interval('20m')->epoch,
                    duration      => 300,
                    magnitude     => 10,
                },
                {
                    release_epoch => $now->minus_time_interval('20m')->epoch,
                    duration      => 1200,
                    magnitude     => 10,
                },
            ];
        });
    my $windows = $c->_get_tick_windows($period);
    is scalar(@$windows), 2, 'two windows';
    is $windows->[0][0], $now->minus_time_interval('5m')->epoch, 'correct start of period';
    is $windows->[0][1], $now->epoch, 'correct end of period';
    is $windows->[1][0], $now->minus_time_interval('35m')->epoch, 'correct start of period';
    is $windows->[1][1], $now->minus_time_interval('20m')->epoch, 'correct end of period';
};

done_testing();
