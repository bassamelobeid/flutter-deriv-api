#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;

# 2000 is probably large enough to avoid collision with
# other auto generated req_id
my $custom_req_id = 2000;

my $skip_sanity_checks = {
    balance     => [qw(schema_v4)],    # balance.balance is string
    transaction => [qw(schema_v4)],    # transaction.amount, balance is string (can publish numbers to fix this, but then it affects balance method)
};

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 300,
        max_response_delay => 3,                      # TODO: will be removed once long delays are fixed specially for website status call.
        skip_sanity_checks => $skip_sanity_checks,    # TODO: Remove once the API started sending the right types.
    ),
);

my $client = $tester->new_client;

$tester->publish(
    transaction => [{
            client  => $client,
            actions => [qw(buy sell)],
        }
    ],
    tick           => [qw(R_100 R_25)],
    website_status => [{site_status => 'up'}],
);

my @subscriptions = ({
        balance => {balance => 1},
    },
    {
        transaction => {transaction => 1},
    },
    {
        ticks => {
            ticks  => 'R_25',
            req_id => ++$custom_req_id
        },
    },
    {
        ticks_history => {
            ticks_history => 'R_100',
            end           => 'latest',
            style         => 'ticks',
            req_id        => ++$custom_req_id,
            count         => 10
        },
    },
    {website_status => {website_status => 1}},
);

my %subscription_args = (
    subscription_list => \@subscriptions,
    token             => $client->{token},
);

subtest 'General subscriptions: all combinations' => sub {
    Future->wait_all(
        $tester->subscribe(
            %subscription_args,
            concurrent => scalar @subscriptions,
        ),
        $tester->subscribe_multiple_times(
            count      => 10,
            concurrent => scalar @subscriptions,
            %subscription_args,
        ),
    )->get;
    Future->wait_all(
        $tester->subscribe_twice(
            %subscription_args,
            concurrent => scalar @subscriptions,
        ),
        $tester->subscribe_after_request(
            token => $client->{token},
            #filterning out API calls that don't support invocation without subsctiption (rejecting subscribe=0)
            subscription_list => [grep { (keys %$_)[0] !~ /^(ticks|transaction)$/ } @subscriptions],
            concurrent        => scalar @subscriptions,
        ),
        (
            map {
                $tester->multiple_subscriptions_forget_one(
                    forget_all => $_,
                    %subscription_args
                    ),
                    $tester->multiple_connections_forget_one(
                    forget_all => $_,
                    %subscription_args
                    ),
            } 0 .. 1
        ),
    )->get;
};

$tester->run_sanity_checks;

# TODO: Make restart_redis work in CircleCI

done_testing;
