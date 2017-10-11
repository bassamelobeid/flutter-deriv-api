#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Cache::RedisDB;
use BOM::Product::ContractFactory qw(produce_contract);

sub create_ticks {
    my @ticks = @_;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });
    }

    return;
}

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
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_,    'frxUSDJPY'] } (-2 .. 2);
    my @after  = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2 .. 2);
    create_ticks(@before, @after);
    my $c = produce_contract({%$args, date_pricing => $expiry});
    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    my $ad = $c->audit_details;
    ok exists $ad->{contract_start}, 'contract start details';
    ok exists $ad->{contract_end},   'contract details details';
    my $c_start = (grep { $_->{name} && $_->{name} =~ /Start/ } @{$ad->{contract_start}})[0];
    is $c_start->{epoch}, $c->date_start->epoch, 'audit start time matches contract start time';
    my $c_entry = (grep { $_->{name} && $_->{name} =~ /Entry/ } @{$ad->{contract_start}})[0];
    is $c_entry->{epoch}, $c->entry_tick->epoch, 'audit entry tick epoch matches contract entry tick epoch';
    is $c_entry->{tick},  $c->entry_tick->quote, 'audit entry tick quote matches contract entry tick quote';

    my $c_end = (grep { $_->{name} && $_->{name} =~ /End/ } @{$ad->{contract_end}})[0];
    is $c_end->{epoch}, $c->date_expiry->epoch, 'audit end time matches contract end time';
    my $c_exit = (grep { $_->{name} && $_->{name} =~ /Exit/ } @{$ad->{contract_end}})[0];
    is $c_exit->{epoch}, $c->exit_tick->epoch, 'audit exit tick epoch matches contract exit tick epoch';
    is $c_exit->{tick},  $c->exit_tick->quote, 'audit exit tick quote matches contract exit tick quote';
};

subtest 'no tick at start & expiry' => sub {
    my @before = map { [100, $now->epoch + $_,    'frxUSDJPY'] } (-2, -1, 1, 2);
    my @after  = map { [100 + 0.001 * $_, $expiry->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    create_ticks(@before, @after);
    my $c = produce_contract({%$args, date_pricing => $expiry});

    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    my $ad = $c->audit_details;
    ok exists $ad->{contract_start}, 'contract start details';
    ok exists $ad->{contract_end},   'contract details details';
    my $c_start = (grep { $_->{name} && $_->{name} =~ /Start/ } @{$ad->{contract_start}})[0];
    ok !$c_start->{tick}, 'tick does not exists at start';
    is $c_start->{epoch}, $c->date_start->epoch, 'audit start time matches contract start time';
    my $c_entry = (grep { $_->{name} && $_->{name} =~ /Entry/ } @{$ad->{contract_start}})[0];
    is $c_entry->{epoch}, $c->entry_tick->epoch, 'audit entry tick epoch matches contract entry tick epoch';
    is $c_entry->{tick},  $c->entry_tick->quote, 'audit entry tick quote matches contract entry tick quote';

    my $c_end = (grep { $_->{name} && $_->{name} =~ /End/ } @{$ad->{contract_end}})[0];
    ok !$c_end->{tick}, 'tick does not exists at expiry';
    is $c_end->{epoch}, $c->date_expiry->epoch, 'audit end time matches contract end time';
    my $c_exit = (grep { $_->{name} && $_->{name} =~ /Exit/ } @{$ad->{contract_end}})[0];
    is $c_exit->{epoch}, $c->exit_tick->epoch, 'audit exit tick epoch matches contract exit tick epoch';
    is $c_exit->{tick},  $c->exit_tick->quote, 'audit exit tick quote matches contract exit tick quote';
};

subtest 'expiry daily' => sub {
    my $expiry = $now->truncate_to_day->plus_time_interval('23h59m59s');
    my @before = map { [100 + 0.001 * $_, $now->epoch + $_, 'frxUSDJPY'] } (-2, -1, 1, 2);
    create_ticks(@before);
    my $mocked_u = Test::MockModule->new('Quant::Framework::Underlying');
    $mocked_u->mock(
        'closing_tick_on',
        sub {
            return Postgres::FeedDB::Spot::Tick->new({
                underlying => 'frxUSJDPY',
                quote      => 100,
                epoch      => $expiry->epoch
            });
        });
    my $c = produce_contract({
        %$args,
        date_pricing => $expiry,
        date_expiry  => $expiry
    });

    ok $c->is_expired,         'contract expired';
    ok $c->is_valid_exit_tick, 'contract has valid exit tick';
    ok $c->expiry_daily,       'expiry daily contract';

    my $ad = $c->audit_details;
    ok exists $ad->{contract_start}, 'contract start details';
    ok exists $ad->{contract_end},   'contract details details';
    my $c_start = (grep { $_->{name} && $_->{name} =~ /Start/ } @{$ad->{contract_start}})[0];
    ok !$c_start->{tick}, 'tick does not exists at start';
    is $c_start->{epoch}, $c->date_start->epoch, 'audit start time matches contract start time';
    my $c_entry = (grep { $_->{name} && $_->{name} =~ /Entry/ } @{$ad->{contract_start}})[0];
    is $c_entry->{epoch}, $c->entry_tick->epoch, 'audit entry tick epoch matches contract entry tick epoch';
    is $c_entry->{tick},  $c->entry_tick->quote, 'audit entry tick quote matches contract entry tick quote';

    my $c_end = (grep { $_->{name} && $_->{name} =~ /Closing/ } @{$ad->{contract_end}})[0];
    is $c_end->{epoch}, $c->date_expiry->epoch, 'audit end time matches contract end time';
};

done_testing();
