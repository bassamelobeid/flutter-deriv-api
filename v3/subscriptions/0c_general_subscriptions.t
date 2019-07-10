#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';
use Future::Utils qw( fmap0 );

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );

my $loop = IO::Async::Loop->new;

$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 300,
        max_response_delay => 10,
        skip_sanity_checks => {
            website_status => [qw(published check_duplicates)],    # Response can be overlapping between publishes
        },
        suite_params => {
            concurrent => 50,
            requests =>  requests(
                #calls => [qw( ticks ticks_history proposal_array proposal website_status )],
                calls => [qw( proposal_array proposal website_status )],
                filter => sub {
                    my $params = shift->{params};
                    my $symbol;
                    if ($params->contract) {
                        $symbol = $params->contract->underlying->symbol;
                    } elsif ($params->ticks_history) {
                        $symbol = $params->ticks_history->underlying->symbol;
                    } elsif ($params->proposal_array) {
                        $symbol = $params->proposal_array->underlying->symbol;
                    } elsif ($params->underlying) {
                        $symbol = $params->underlying->symbol;
                    } else {
                        return 1;
                    }
                    # Checking R_100 only, for faster tests.
                    $symbol eq 'R_100';
                },
            ),    
        }
    ),
);

subtest 'General subscriptions: proposal, proposal_array & website_status' => sub {
    
    Future->needs_all(
        $tester->subscribe_multiple_times(count => 10), $tester->subscribe_twice, $tester->subscribe,
        $tester->subscribe_after_request,     $tester->multiple_subscriptions_forget, $tester->multiple_subscriptions_forget_all,
        $tester->multiple_connections_forget, $tester->multiple_connections_forget_all,
    )->get;
    
    $tester->run_sanity_checks;
};

done_testing;
