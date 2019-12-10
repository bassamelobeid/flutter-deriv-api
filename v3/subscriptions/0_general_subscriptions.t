#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );
use BOM::Test::WebsocketAPI::Parameters qw( clients );

my ($default_client) = grep { $_->loginid eq 'MLT90000000' } clients()->@*;
my $default_token = $default_client->token;
my $loop = IO::Async::Loop->new;

$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 90,
        max_response_delay => 3,
        skip_sanity_checks => {
            # Response can be overlapping between publishes
            # website status is not added to the published list ATM
            website_status => [qw(published check_duplicates)],
            history        => [qw(check_duplicates)],
        },
        suite_params       => {
            concurrent => 200,
            token      => $default_token,
            requests   => requests(
                calls  => [qw( buy transaction balance ticks ticks_history proposal website_status )],
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

subtest 'General subscriptions: all calls except balance_all' => sub {
    Future->needs_all(
        $tester->subscribe_multiple_times(count => 10),
        $tester->subscribe_twice,
        $tester->subscribe,
        $tester->subscribe_after_request,
        $tester->multiple_connections_forget,
        $tester->multiple_connections_forget_all,
    )->get;

    $tester->run_sanity_checks;
};


done_testing;
