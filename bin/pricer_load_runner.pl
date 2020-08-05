#!/usr/bin/env perl 
use strict;
use warnings;
use JSON::MaybeXS;
use feature qw(say);
use Getopt::Long;
use Pod::Usage;
use List::Util qw ( max );
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use URI;
use Email::Stuffer;
use YAML::Tiny;
use Email::Sender::Transport::SMTP;
use Sys::Hostname;
use URI::QueryParam;
use Data::Dumper;

=head1 NAME

pricer_load_runner.pl  - Wrapper to  run the proposal_pricer script at different levels until the queue overflows. 

=head1 DESCRIPTION

This script is a wrapper around the proposal_sub.pl script designed to run that script at different levels until the pricing queue overflows. Once the queue 
has overflowed it sends an email with the stats to the QA team. 

In order to run this script you must set the environment variables 

=over 4

=item * DD_APP_KEY  with the Application key obtained from the development organisation in Datadog under the Integrations section

=item * DD_API_KEY  with the API key obtained from the development organisation in Datadog under the Integrations section

=back

or

Set them in the YAML file C</etc/rmg/loadtest_datadog.yml>
In this format 

    DD_APP_KEY: asasdasd
    DD_API_KEY: 123123asasd


If you are using a different SMTP server to the systems default  you can specify the settings in C</etc/rmg/loadtest_smtp_secrets.yml> 
In this format 

   SMTP_SERVER: smtp.mandrillapp.com
   SMTP_PORT: 587
   SMTP_USER: someone@binary.com
   SMTP_PASSWORD: some_password 


=head1 SYNOPSIS

    perl pricer_load_runner.pl -h -s -t -e -m 

=over 4

=item * --time|-t  The amount of time in seconds that the proposal_sub.pl script will be run for, for each subscription amount. Defaults to 120 seconds. Setting this lower than 60 seconds could lead to unreliable results as there is an inbuilt 60 second delay on the statistics gathering. 

=item * --subscriptions|-s : The number of subscriptions per connection, Connections are set at 5 so the figure here will result in 5 times more subscriptions. Default is 10.  

=item * --mail_to|-e  : Address to email the result to, Optional if left empty it won't email.  For multiple addresses separate with a comma.  

=item * --hostname|-n :  The hostname which in DataDog indicates the statistics to be used for the measurements. If not supplied defaults to the current servers name.  

=item * --markets|-m : The markets that the tests should be run with. If supplied it will perform an individual test against each market. If not supplied will run test
against all markets. Supply as a comma separated list. Options are 'forex', 'synthetic_index', 'indices', 'commodities'. 

=item * --iterations|-i  The number of tests runs  to perform against each market type to achieve an average score. In theory the higher this number the more accurate the results.  

=item * --help|-h : This help info. 

=back


=cut

GetOptions(
    't|time=i'          => \my $check_time,
    's|subscriptions=i' => \my $initial_subscriptions,
    'n|hostname=s'      => \my $hostname,
    'e|mail_to=s'       => \my $mail_to,
    'm|markets=s'       => \my $markets,
    'i|iterations=i'    => \my $iterations,
    'h|help'            => \my $help,
);

pod2usage(
    {
        -verbose  => 99,
        -sections => "NAME|SYNOPSIS|DESCRIPTION"
    }
) if $help;

# Set Defaults
$check_time            = $check_time            // 120;
$initial_subscriptions = $initial_subscriptions // 10;
if ( !$hostname ) {
    $hostname = hostname();
}
my @mails_to = split( ',', $mail_to ) if $mail_to;
$iterations = $iterations // 1;
my @markets_to_use = ("forex", "synthetic_index", "indices", "commodities");
@markets_to_use = split( ',', $markets ) if ($markets);
my %valid_markets = (
    'forex'           => 1,
    'synthetic_index' => 1,
    'indices'         => 1,
    'commodities'     => 1
);

for (@markets_to_use) {
    if ( !defined( $valid_markets{$_} ) ) {
        say 'Invalid Market Type: ' . $_;
        pod2usage(
            {
                -verbose  => 99,
                -sections => "NAME|SYNOPSIS|DESCRIPTION"
            }
        );
    }
}
my $api_key = $ENV{DD_API_KEY};
my $app_key = $ENV{DD_APP_KEY};
if ( ( !$api_key || !$app_key ) and ( -e '/etc/rmg/loadtest_datadog.yml' ) ) {
    my $data_dog_keys = YAML::Tiny->read('/etc/rmg/loadtest_datadog.yml');
    $api_key = $data_dog_keys->[0]->{DD_API_KEY};
    $app_key = $data_dog_keys->[0]->{DD_APP_KEY};
}
if ( !$app_key || !$api_key ) {
    die
" You need to set the DD_API_KEY and DD_APP_KEY variables or populate /etc/rmg/loadtest_datadog.yml";
}

my $smtp_transport;

if ( -e '/etc/rmg/loadtest_smtp_secrets.yml' ) {
    my $smtp_keys = YAML::Tiny->read('/etc/rmg/loadtest_smtp_secrets.yml');
    $smtp_keys      = $smtp_keys->[0];
    $smtp_transport = Email::Sender::Transport::SMTP->new(
        host          => $smtp_keys->{SMTP_SERVER},
        port          => $smtp_keys->{SMTP_PORT},
        sasl_username => $smtp_keys->{SMTP_USER},
        sasl_password => $smtp_keys->{SMTP_PASSWORD}
    );

}

my $command = '/home/git/regentmarkets/bom-test/bin/proposal_sub.pl';
my $json    = JSON->new();
my $loop    = IO::Async::Loop->new();
my $http =
  Net::Async::HTTP->new(
    headers => { DD_API_KEY => $api_key, DD_APPLICATION_KEY => $app_key } );
my $queue_size_query    = "sum:pricer_daemon.queue.size{host:$hostname}";
my $overflow_size_query = "sum:pricer_daemon.queue.overflow{host:$hostname}";
my $start               = 1;
my $timer;
my $market = shift @markets_to_use;

my $test_start_time = time;    #used to build the Datadog link in the email.
my $test_end_time   = 0;
my $pid =
  open( my $fh, "-|",
    "$command -s $initial_subscriptions -c 5 -r $check_time -m $market&" )
  or die $!;

# I guess because this runs a shell then the script that the PID is always 1 higher than
# returned.  This may not be reliable but since this is just a test running script maybe
# we can get away with it?
$pid++;
say 'pid ' . $pid;
close $fh;

# Kill the sub script if Ctrl-C is pressed.
$SIG{'INT'} = sub {
    exit;    #this will end up running the END block
};

#Catch on Die , kill subscript if running
END {
    `kill $pid` if $pid;
    exit;
}

# Main logic, triggers at checktime seconds and checks the results from Datadog.   If the queue has overflowed
# after an initial start up time it will stop the testing and send the results.
# Otherwise it will adjust the subscription amount and run the test again.
my $run_recorder;
my $subscriptions  = $initial_subscriptions;
my $number_of_runs = 1;
my $new_market = 0;
my $overflow_buffer_amount = get_overflow_buffer_amount($check_time);

$timer = IO::Async::Timer::Periodic->new(
    interval => $check_time,

    on_tick => sub {
        my ( $overflow_amount, $max_queue_size ) = check_stats();

        # We have completed a cycle so kill off the current load test
        `kill $pid` if $pid;
        $pid = undef;
        if ( $overflow_amount == 0 || $start == 1 ) {

            #this will catch it if we start with our subscription number too high and overflow straight away.
            if ( $overflow_amount > 0 && $start ) {
                say 'Overflowed on First run,  reducing subscription count';
                $subscriptions -= int( $subscriptions * .3 );
            }
            else {
                say ' No Overflow at ' . $max_queue_size;
                # check if its first run of next market. it should be running with $intial_subscription & dont need to increase the number.
                $subscriptions += int( $subscriptions * .3 ) unless($new_market);
                $start = 0;
            }
            $new_market = 0;
            $pid =
              open( my $fh, "-|",
                "$command -s $subscriptions -c 5 -r $check_time -m $market&" )
              or die $!;
            $pid++;
        }
        else {
            if ( $number_of_runs < $iterations ) {
                say 'Run Number ' . $number_of_runs;

                say 'Overflowed at queue_size ' . $max_queue_size;
                $run_recorder->{$market}->{$number_of_runs}
                  ->{overflowed_queue_size} = $max_queue_size;
                $start = 1;
                $number_of_runs++;
                $subscriptions = $initial_subscriptions;
            }
            else {
                $test_end_time = time;
                $run_recorder->{$market}->{$number_of_runs}
                  ->{overflowed_queue_size} = $max_queue_size;
                say 'Overflowed at queue_size ' . $max_queue_size;
                say Dumper($run_recorder);
                if( $market = shift @markets_to_use) {
                    say "trying to get next market ".$market;
                    $start = 1;
                    $number_of_runs = 1;
                    $subscriptions = $initial_subscriptions;
                    $new_market = 1;
                } else {
                    email_result( $run_recorder, \@mails_to, $smtp_transport )
                      if scalar(@mails_to);
                    $timer->stop;
                    $loop->stop;
                }
            }
        }
    },
);
$timer->start;
$loop->add($http);
$loop->add($timer);
$loop->run();

=head1 Functions

=head2 check_stats

Description: Gets the queue size and overflow from Datadog. Subtract the overflow_buffer_amount from overflow_amount to make sure its not momentary overflow.
Takes no arguments. 


Returns an Array (
    how many results where the queue overflowed, 
    The max number of the queue size
 );

=cut

sub check_stats {
    my $max_queue_size  = 0;
    my $overflow_amount = 0;
    my $current_time    = time;
    my $past_time =
      ( $current_time - $check_time ) + 60; #ignore the first minute of startup.
    my $uri = URI->new('https://api.datadoghq.com/api/v1/query');
    $uri->query_form_hash(
        from  => $past_time,
        to    => $current_time,
        query => $queue_size_query
    );

    my $queue_size_request =
      $http->do_request( uri => URI->new( $uri ), )->on_done(
        sub {
            my @results = process_response(shift);
            die "No Queue size available from Datadog, check API details"
              if !@results;
            $max_queue_size = max(@results);
            say 'Queue Size ' . $max_queue_size;
        }
      )->on_fail( sub { die "unable to get queue_size_stats" } );

    $uri->query_form_hash(
        from  => $past_time,
        to    => $current_time,
        query => $overflow_size_query
    );
    my $overflow_size_request = $http->do_request(
        uri => URI->new( $uri ),

      )->on_done(
        sub {
            my @results = process_response(shift);
            die "No overflow size available from Datadog, check API details"
              if !@results;
            my @overflowed = grep { ( $_ > 0 ) } @results;
            $overflow_amount = scalar @overflowed;
            say 'Overflowed ' . scalar @overflowed . ' of ' . scalar @results;
        }
      )->on_fail( sub { die "unable to get queue_overflow_stats" } );
    Future->needs_all( $queue_size_request, $overflow_size_request )->get();
    #handle the case when there is momentary overflow
    my $overflow_amount_minus_buffer = 0;
    if($overflow_amount) {
            $overflow_amount_minus_buffer = ($overflow_amount > $overflow_buffer_amount)? $overflow_amount - $overflow_buffer_amount:0;
    }
    return ( $overflow_amount_minus_buffer, $max_queue_size );
}

=head2 process_response

Description: decode and extract the result data from the Data dog response
Takes the following arguments as parameters

=over 4

=item - $response  Raw response from DataDog API call. 


=back

Returns a flat array of results; 

=cut

sub process_response {
    my ($response)       = @_;
    my $json_response    = $response->content;
    my $decoded_response = $json->decode($json_response);
    my $results          = $decoded_response->{series}->[0]->{pointlist};
    return map { $_->[1] } @$results;
}

=head2 email_result

Description: Send the results 
Takes the following arguments as parameters

=over 4

=item - $overflowed_at:   an integer of the  queue size that it overflowed at. 

=item - $mails_to:  An Array ref of the email addresses to  send the result to.  

=item - $smtp_transport:  (optional)  A L<Email::Sender::Transport::SMTP> object to specify custom SMTP arguments. Otherwise it will use the default. 

=back

Returns undef

=cut

sub email_result {
    my ( $overflow_data, $mails_to, $smtp_transport ) = @_;
    say "emailing result";

    #Add a bit of buffer either side  so there is context to the graphs.
    my $dashboard_start_time = ( $test_start_time - 300 ) * 1000;
    my $dashboard_end_time   = ( $test_end_time + 300 ) * 1000;
    my $body                 = "Here are the stats for the Load testing run \n";
    foreach my $market ( keys(%$overflow_data) ) {
        $body .= "market - $market\n Overflowed at \n";
        foreach my $run ( keys( $overflow_data->{$market}->%* ) ) {

            $body .= "- "
              . $overflow_data->{$market}->{$run}->{overflowed_queue_size}
              . "\n";
        }
    }
    $body .= "
    Datadog link =  https://app.datadoghq.com/dashboard/8w7-rtw-jse/qaloastest-pricer-queue?from_ts=$dashboard_start_time&live=false&to_ts=$dashboard_end_time; 
    ";
    my $email_stuffer =
      Email::Stuffer->from('loadtest@binary.com')->to(@$mails_to)
      ->subject('Load Test Results')->text_body($body);
    if ($smtp_transport) {
        $email_stuffer->transport($smtp_transport);
    }
    $email_stuffer->send_or_die;
    return undef;
}

=head2 get_overflow_buffer_amount

Description: we think that subtracting 1 from overflow_amount every 60 seconds can help us find momentary overflow. 
Since checktime is variable so overflow amount should be calculated dynamically.
TODO: this will serve our purpose as of now since our test runs for max 120 seconds but need to improve it if we go for running test for an hour or so.

=over 4

=item - $check_time_amount: the amount of time in seconds got from argments

=back

Returns integer value of buffer amount

=cut

sub get_overflow_buffer_amount {
    my $check_time_amount = @_;
    return int($check_time_amount/60);
}
