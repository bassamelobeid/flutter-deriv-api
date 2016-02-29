#!/usr/bin/perl -w

package BOM::Product::Expiryd;

use Moose;
with 'App::Base::Daemon';
with 'BOM::Utility::Logging';

has pids => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub{[]},
);

has shutting_down => (
    is      => 'rw',
    isa     => 'Num',
    default => 0,
);

use ExpiryQueue qw( dequeue_expired_contract get_queue_id);
use List::Util qw(max);
use Cache::RedisDB;
use Time::HiRes;
use Try::Tiny;

use BOM::Platform::Client;
use BOM::Product::Transaction;

sub documentation {
    return qq/This daemon sells off expired contracts in soft real-time./;
}

sub options {
    return [{
            name          => "threads",
            documentation => "Number of processes to spawn",
            option_type   => "integer",
            default       => 5,
        },
    ];
}

sub daemon_run {
    my $self = shift;

    for (my $i = 1; $i < $self->getOption('threads'); $i++) {
        my $pid;
        select undef, undef, undef, 0.2 until defined ($pid = fork);
        if ($pid) {
            push @{$self->pids}, $pid;
        } else {
            @{$self->pids} = ();
            $self->_daemon_run;
            CORE::exit 1;
        }
    }

    $self->_daemon_run;
}

sub _daemon_run {
    my $self = shift;

    $self->warn("Starting as PID $$.");
    my $redis = Cache::RedisDB->redis;
    while (1) {
        my $now = time;
        my $next_time = $now + 1; # we want this to execute every second
        my $iterator = dequeue_expired_contract();
        # Outer `while` to live through possible redis disconnects/restarts
        while (my $info = $iterator->()) {    # Blocking for next available.
            try {
                my $contract_id = $info->{contract_id};
                my $client = BOM::Platform::Client->new({loginid => $info->{held_by}});
                if ($info->{in_currency} ne $client->currency) {
                    $self->warn('Skip on currency mismatch for contract '
                            . $contract_id
                            . '. Expected: '
                            . $info->{in_currency}
                            . ' Client uses: '
                            . $client->currency);
                    next;
                }
                # This returns a result which might be useful for reporting
                # but for now we will ignore it.
                my $is_sold = BOM::Product::Transaction::sell_expired_contracts({
                        client       => $client,
                        source       => 1063,            # Third party application 'binaryexpiryd'
                        contract_ids => [$contract_id]});

                if (not $is_sold or $is_sold->{number_of_sold_bets} == 0) {
                    $info->{sell_failure}++;
                    my $cid = get_queue_id($info);
                    if ($info->{sell_failure} <= 5) {
                        my $future_epoch = $now + 2;
                        $redis->rpush('EXPIRYQUEUE::SELL_FAILURE_' . $future_epoch, $cid);
                    }
                }
            };    # No catch, let MtM pick up the pieces.
        }
        Time::HiRes::sleep(max(0,$next_time - Time::HiRes::time));
    }
}

sub handle_shutdown {
    my $self = shift;
    return if $self->shutting_down;
    $self->shutting_down(1);
    $self->warn("PID $$ is shutting down.");
    kill TERM => @{$self->pids}; # for children this list is empty
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Product::Expiryd->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;
