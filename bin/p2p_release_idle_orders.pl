#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use Syntax::Keyword::Try;

use BOM::User::Client;
use Log::Any qw($log);
use Log::Any::Adapter 'Stderr';

=head1 Name

p2p_release_idle_orders - TEMPORARY script for reliasing orders with no activity

=cut

use constant DEFAULT_TTL => 60 * 60 * 24;
GetOptions(
    'b|buyers=s' => \my $client_loginids,
    't|ttl=i'    => \my $order_ttl,
) or die;

$order_ttl       //= DEFAULT_TTL;
$client_loginids //= '';

my @client_loginids = split q{,} => $client_loginids;

my $now = time;

CLIENT:
for my $client_loginid (@client_loginids) {
    next CLIENT unless $client_loginid;

    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $client_loginid});
    } catch ($e) {
        $log->warnf("Error when get client of login id $client_loginid. more detail: %s", $e);
    }
    unless ($client) {
        warn 'Incorrect  buyer login id: ' . $client_loginid . "\n";
        next CLIENT;
    }

    my $orders = $client->_p2p_orders(
        loginid => $client->loginid,
        status  => ['pending']);

    unless ($orders && @$orders) {
        warn "Client  $client_loginid have no pending orders\n";
        next CLIENT;
    }

    ORDER:
    for my $order (@$orders) {
        my $lifetime = $now - Date::Utility->new($order->{created_time})->epoch;
        next ORDER unless $lifetime > $order_ttl;

        try {
            $client->p2p_order_cancel(id => $order->{id});
        } catch ($e) {
            warn "Fail to cancel order $order->{id}: $e\n";
        };

        warn "Order $order->{id} is successfully cancelled from buyer account $client_loginid\n";
    }
}

