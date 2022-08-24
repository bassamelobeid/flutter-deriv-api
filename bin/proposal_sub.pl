#!/usr/bin/env perl 
use strict;
use warnings;

use feature qw(say);

no indirect;

use Pod::Usage;
use Getopt::Long;
use Log::Any::Adapter qw(DERIV),
    stderr    => 1,
    log_level => 'warn';
use Log::Any qw($log);
use Path::Tiny;
use BOM::Test::LoadTest::Proposal;

=head1 NAME

proposal_sub.pl  - Load testing script for proposals

=head1 DESCRIPTION

This script is designed to create a load on Binary Pricing components via the proposal API call. It can create many connections with each connection having
many subscriptions. Subscriptions are randomly forgotten and new ones established to take their place in order to emulate what would happen in production. 
The script currently contains no measurement ability so that will need to be done externally via Datadog or other means.  

=head1 SYNOPSIS

    perl proposal_sub.pl -h -e -a -c -s -f -t -m -r -d

=over 4

=item * --token|-t  The API token to use for calls, this is optional and calls are not authorized by default.

=item * --app_id|-a : The application ID to use for API calls, optional and is set to 1003 by default. 

=item * --endpoint|-e : The endpoint to send calls to, optional by default is set to 'ws://127.0.0.1:5004 which is the local websocket server on QA. 

=item * --connections|-c :  The number of  connections to establish, optional by default it is set to 1.

=item * --subscriptions|-s : The number of subscriptions per connection, optional by default it is set to 5

=item * --forget_time|-f : The upper bound of the random time in seconds to forget subscriptions. If 0 will not forget subscriptions. Default is 0;

=item * --test_duration|-r : The number of seconds to run the test for before exiting.  If 0 will not exit. Defaults to 0 

=item * --markets|-m :  a comma separated list of markets to include choices are 'forex', 'synthetic_index', 'indices', 'commodities'.  If not supplied defaults to all. 

=item * --debug|-d : Display some debug information.

=back


=cut

GetOptions(
    't|token=s'         => \my $token,
    'a|app_id=i'        => \my $app_id,
    'e|endpoint=s'      => \my $end_point,
    'c|connections=i'   => \my $connections,
    's|subscriptions=i' => \my $subscriptions,
    'f|forget_time=i'   => \my $forget_time,
    'm|markets=s'       => \my $markets,
    'r|run_time=i'      => \my $test_duration,
    'd|debug'           => \my $debug,
    'h|help'            => \my $help,
);

pod2usage({
        -verbose  => 99,
        -sections => "NAME|SYNOPSIS|DESCRIPTION"
    }) if $help;

# Set Defaults
$app_id        = $app_id        // 16303;
$end_point     = $end_point     // 'ws://127.0.0.1:5004';
$connections   = $connections   // 1;
$subscriptions = $subscriptions // 5;
$forget_time   = $forget_time   // 0;
$test_duration = $test_duration // 0;

Log::Any::Adapter->set(
    'DERIV',
    stderr    => 1,
    log_level => 'debug'
) if $debug;

my @markets_to_use;
if ($markets) {
    @markets_to_use = split(',', $markets);
}

my $load_tester = BOM::Test::LoadTest::Proposal->new(
    end_point               => $end_point,
    app_id                  => $app_id,
    number_of_connections   => $connections,
    number_of_subscriptions => $subscriptions,
    forget_time             => $forget_time,
    test_duration           => $test_duration,
    markets                 => \@markets_to_use,
    token                   => $token,
);

my @valid_markets = $load_tester->all_markets();

for my $market (@markets_to_use) {
    if (!grep { $market eq $_ } @valid_markets) {
        $log->info('Invalid Market Type: ' . $_);
        pod2usage({
            -verbose  => 99,
            -sections => "NAME|SYNOPSIS|DESCRIPTION"
        });
    }
}

path('/tmp/proposal_sub.pid')->spew($$);
$load_tester->run_tests();
