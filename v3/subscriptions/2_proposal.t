#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use BOM::Test::WebsocketAPI;
use BOM::Test::Helper::MockRPC;
use BOM::Test::Helper::MockRPC::SendAsk;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';
my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new()
);

my %proposal_request = (
    amount => 10,
    basis => "stake",
    contract_type => "PUT",
    currency => "USD",
    duration => 5,
    duration_unit => "h",
    proposal => 1,
    subscribe => 1,
    symbol => "frxAUDJPY",
    passthrough => { mock_rpc_request_id => 1 },
);
my %proposal_request2 = (
    amount => 10,
    basis => "stake",
    contract_type => "PUT",
    currency => "USD",
    duration => 6,
    duration_unit => "m",
    proposal => 1,
    subscribe => 1,
    symbol => "frxAUDJPY",
    passthrough => { mock_rpc_request_id => 2 },
);
my $dummy_results = BOM::Test::Helper::MockRPC::SendAsk::generate_from_requests([\%proposal_request, \%proposal_request2]);
my $mock_rpc = BOM::Test::Helper::MockRPC->new();
$mock_rpc->mocked_methods($dummy_results);
$mock_rpc->start;
$tester->configure(max_response_delay=>50);
$tester->publish(proposal => [\%proposal_request,\%proposal_request2]);

my $requests = [{proposal => \%proposal_request},{proposal => \%proposal_request2}];

subtest 'proposal with mocked RPC' => sub {
    Future->needs_all(
        $tester->proposal_subscribe(%proposal_request),
        $tester->subscribe_twice(
            subscription_list => $requests,
            concurrent        => 2,
        ),
        $tester->subscribe_multiple_times(
            count             => 10,
            concurrent        => 2,
            subscription_list => $requests,
        ),
        $tester->multiple_subscriptions_forget_one(
            subscription_list => $requests,
            concurrent        => 2,
        ),
        $tester->multiple_connections_forget_one (
            subscription_list => $requests,
            concurrent        => 2,
        ),
    )->get;
};

done_testing;
