#!/usr/bin/env perl 
use strict;
use warnings;

use Future::Utils qw(fmap_void);
use List::Util qw(min);
use IO::Async::Loop;
use Net::Async::Redis;
use Future::AsyncAwait;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use Getopt::Long;
use Data::Dumper;
use BOM::Config::Redis;

=head1 NAME

C<remove-queued-methods.pl> - drop any requests from the queue matching commandline list

=head1 SYNOPSIS

    perl remove-queued-methods.pl [--redis redis://...]  [--stream general] mt5_new_account,mt5_deposit,mt5_withdrawal
    
=cut

use constant REDIS_CONNECTION_TIMEOUT => 5;

my $redis_config = BOM::Config::Redis::redis_config('rpc', 'write');

GetOptions(
    'stream|s=s@'  => \(my $streams             = ['general']),
    'redis|r=s'    => \(my $redis_uri           = $redis_config->{uri}),
    'interval|i=i' => \(my $interval_in_seconds = 30),
) or die("Error in input arguments\n");

my %methods = map { $_ => 1 } map { split /,/ } @ARGV;
$log->infof('Will remove RPC calls matching: %s', join(',', sort keys %methods));

my $loop = IO::Async::Loop->new;
$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => $redis_uri
    )
);

async sub remove_methods {
    my ($stream) = @_;
    my $limit = 50;
    my $total = 0;
    my $removed = 0;
    my $prev = '0';
    while(1) {
        my ($response) = await $redis->xrange($stream, $prev, '+', COUNT => $limit);
        $log->infof('Have %d items', 0 + @$response);
        my @removal;
        for my $item ($response->@*) {
            ++$total;
            my $id = $item->[0];
            my %data = $item->[1]->@*;
            $log->infof('ID %s data %s', $id, \%data);
            my $rpc = $data{rpc} or die 'Found request with no RPC method, queue format invalid? ' . Dumper(\%data);
            if(exists $methods{$rpc}) {
                push @removal, [ $id, $rpc ];
            }
            $prev = $id;
        }
        for my $removal (@removal) {
            my ($id, $rpc) = $removal->@*;
            $log->infof('Removing ID %s which is %s', $id, $rpc);
        }
        await $redis->xdel($stream, map { $_->[0] } @removal) if @removal;
        $removed += @removal;

        last unless @$response >= $limit;
        await $loop->delay_future(after => 0.005);
    }
    $log->infof('Removed %d of %d total items from queue %s', $removed, $total, $stream);
    return;
}

(async sub {
    await Future->wait_any(
        $redis->connected,
        $loop->timeout_future(after => REDIS_CONNECTION_TIMEOUT)
    );
    for my $stream (@$streams) {
        await remove_methods($stream);
    }
})->()->get;
