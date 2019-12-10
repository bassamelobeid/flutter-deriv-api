#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Future::Utils qw( fmap0 );
use feature qw(state);

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );
use BOM::Test::WebsocketAPI::Parameters qw( clients test_params );

my ($default_client) = grep { $_->loginid eq 'MLT90000000' } clients()->@*;
my $default_token = $default_client->token;
my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 60 * 3, # 3 mins should be more than enough
        max_response_delay => 3,
    ),
);

subtest 'Subscribe to balance (all)' => sub {
    $tester->configure(
        suite_params       => {
            concurrent => 100,
            requests   => requests(calls => [qw( balance_all )]),
            token      => $default_token,
        }
    );

    # Make sure we get at least 2 published responses
    $tester->subscribe(min_subscriptions => (test_params()->{client}->@* + 2))->get;
    $tester->run_sanity_checks;
};

subtest "Buy subscriptions: Only R_* and frxUSD*" => sub {
    my @args = map {
        +{
            requests => requests(
                client => $_,
                calls  => [qw(buy)],
                filter => sub {
                    shift->{params}->contract->underlying->symbol =~ /R_.*|frxUSD.*/;
                }
            ),
            token => $_->token,
        }
    } clients()->@*;

    $tester->configure(
        suite_params       => {
            concurrent => scalar(@args) * 100,
        }
    );

    Future->needs_all(map { $tester->buy_then_sell_contract($_->%*) } @args)->get;
    Future->needs_all(map { $tester->poc_no_contract_id($_->%*) } @args)->get;
};

subtest "Tick Subscriptions: frx* and R_*" => sub {
    $tester->configure(
        suite_params => {
            concurrent => 100,
            requests   => requests(
                calls  => [qw(ticks ticks_history)],
                filter => sub {
                    my $params = shift->{params};
                    $params = $params->ticks_history if $params->ticks_history;
                    $params->underlying->symbol =~ /frx.*|R_.*/;
                },
            ),
        });
    $tester->subscribe->get;
    $tester->subscribe_twice->get;
    $tester->subscribe_multiple_times(count => 10)->get;
};

subtest "Tick Subscriptions: Subscribe and forget R_* only" => sub {
    $tester->configure(
        suite_params => {
            concurrent => 50,
            requests   => requests(
                calls  => [qw(ticks ticks_history)],
                filter => sub {
                    my $params = shift->{params};
                    $params = $params->ticks_history if $params->ticks_history;
                    $params->underlying->symbol =~ /R_.*/;
                },
            ),
        });
    $tester->multiple_subscriptions_forget->get;
    $tester->multiple_subscriptions_forget_all->get;
    $tester->multiple_connections_forget->get;
    $tester->multiple_connections_forget_all->get;
};

subtest 'Publish gap test: all calls in parallel' => sub {
    $tester->configure(
        suite_params => {
            concurrent => 50,
            token    => $default_token,
            requests => requests(
                filter => sub {
                    state $count;
                    my $params = delete $_[0]->{params};
                    ++$count->{$_[0]->{request}} == 1;
                },
            ),
        });

    $tester->publish_gap->get;
};

subtest 'UTF8 test:' => sub {
    $tester->configure(suite_params => {});

    $tester->check_utf8_fields_work->get;
};

done_testing;
