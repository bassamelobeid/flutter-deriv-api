#!/usr/bin/env perl 
use strict;
use warnings;

use feature qw(say);

no indirect;

use Future;
use Future::Utils qw(fmap0);
use IO::Async::Loop;
use Binary::API;
use Net::Async::BinaryWS;
use Future::AsyncAwait;
use Pod::Usage;
use Syntax::Keyword::Try;
use Getopt::Long;
use DateTime;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use Log::Any qw($log);
use JSON::MaybeXS;

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

=item * --run_seconds|-r : The number of seconds to run the test for before exiting.  If 0 will not exit. Defaults to 0 

=item * --markets|-m :  a comma separated list of markets to include choices are 'forex', 'synthetic_index', 'indices', 'commodities'.  If not supplied defaults to all. 

=item * --debug|-d : Display some debug information.

=back


=cut

use constant TIMEOUT => 10;
GetOptions(
    't|token=s'         => \my $token,
    'a|app_id=i'        => \my $app_id,
    'e|endpoint=s'      => \my $end_point,
    'c|connections=i'   => \my $connections,
    's|subscriptions=i' => \my $subscriptions,
    'f|forget_time=i'   => \my $forget_time,
    'm|markets=s'       => \my $markets,
    'r|run_time=i'      => \my $run_seconds,
    'd|debug'           => \my $debug,
    'h|help'            => \my $help,
);

pod2usage(
    {
        -verbose  => 99,
        -sections => "NAME|SYNOPSIS|DESCRIPTION"
    }
) if $help;

# Set Defaults
$app_id        = $app_id        // 1003;
$end_point     = $end_point     // 'ws://127.0.0.1:5004';
$connections   = $connections   // 1;
$subscriptions = $subscriptions // 5;
$forget_time   = $forget_time   // 0;
$run_seconds   = $run_seconds   // 0;

my %multipliers = (
    m => 1,
    h => 60,
    d => 1440
);

Log::Any::Adapter->set( 'Stderr', log_level => 'debug' ) if $debug;
my @markets_to_use;
if ($markets) {
    @markets_to_use = split( ',', $markets );
}

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

my %subs;    # Stores current subscriptions
my $json = JSON::MaybeXS->new( pretty => 1 );
my $loop = IO::Async::Loop->new;

my $main_connection = create_connection();
my $active_symbols = get_active_symbols( $main_connection, \@markets_to_use );
$log->debug( "Active Symbols \n" . "@$active_symbols" );
if ( !@$active_symbols ) { die "No Active Symbols Available" }
my $contracts_for = get_contracts_for( $main_connection, $active_symbols );

# Will cause script to exit when run_seconds is reached.
my $run_timer_future;
if ($run_seconds) {
    $run_timer_future = $loop->delay_future( after => $run_seconds )
      ->on_done( sub { say 'finished after ' . $run_seconds; } );
}
else {
    $run_timer_future = $loop->new_future;    #A Future that will never be done.
}

# Main Loop starts up the number of connections to the Websocket API.
fmap0 {
    try {
        create_subscriptions(shift);
    }
    catch {

        warn 'Failed ' . $@;
        return Future->done;
    }
}
foreach => [ ( 1 .. $connections ) ],
  concurrent => $connections;

$loop->await($run_timer_future)->get;
exit 1;

=head1 Functions

Functions from here down.

=head2 create_subscriptions

Description:  Creates a connection then triggers  the number of subscriptions passed
as the -s parameter. 
Takes the following argument.

=over 4

=item  $connection_number : the counter for the connection number. 

=back

Returns a L<Future>

=cut

async sub create_subscriptions {
    my ($connection_number) = @_;
    say 'Connection Number ' . $connection_number;
    my $connection = create_connection();
    fmap0 {
        try {
            subscribe( $connection, $connection_number );
        }
        catch {
            warn 'Creating a subscription Failed ' . $@;
            return Future->done;
        }
    }
    foreach => [ ( 1 .. $subscriptions ) ],
      concurrent => $subscriptions;

}

=head2 create_connection

Description: Responsible for creating the connections, times out if longer than TIMEOUT seconds
will attempt to authorize if a token is passed via the -t parameter. 
Takes no arguments.


Returns a L<Net::Async::BinaryWS>

=cut

sub create_connection {

    $loop->add(
        my $connection = Net::Async::BinaryWS->new(
            endpoint => $end_point,
            app_id   => $app_id,
        )
    );
    Future->wait_any(
        $connection->connected->then(
            sub {
                if ($token) {
                    return $connection->api->authorize( authorize => $token )
                      ->on_fail(
                        sub {
                            warn 'Authorize Failed ' . shift->body->message;
                            Future->done;
                        }
                      )

                }
                else {
                    return Future->done;
                }

            }
        ),
        $loop->timeout_future( after => TIMEOUT )->on_fail(
            sub {
                fail("timeout connecting to $end_point");
            }
        )
      )->transform(
        done => sub {
            $connection;
        }
      )->get;

    return $connection;
}

=head2 subscribe

Description: Creates one subscription to a proposal,  subscriptions will randomly be forgotten ,  when they do
another subscription will be created and the same will happen if an error occurs.  Since failed and forgotten
subscriptions are recreated there should be a constant number of subscriptions during a run.  
Takes the following arguments 

=over 4

=item - $connection :  An established L<Net::Async::BinaryWS> connection

=item - $connection_number : A counter to indicate which connection this is on.

=back

Returns a L<Future>

=cut

sub subscribe {
    my ( $connection, $connection_number ) = @_;
    my $sub;
    my $first  = 1;
    my $future = $loop->new_future;
    my $symbol = $active_symbols->[ int( rand( scalar( $active_symbols->@* ) ) ) ];
    my @contract_types = qw( PUT CALL PUTE CALLE RESETPUT);    #just PUT for now
    my $contract_type = $contract_types[ int( rand(@contract_types) ) ];
    say 'Subscribing to '
      . $symbol
      . ' using using connection number '
      . $connection_number;
    my $params = get_params( $contract_type, $symbol, $contracts_for );
    my $retry_count = 0;

    while ( !$params || $retry_count < 5 ) {
        $symbol = $active_symbols->[ int( rand( $active_symbols->@* ) ) ];
        $params = get_params( $contract_type, $symbol, $contracts_for );
        $retry_count++;
    }
    $log->debug( "Subscribing with \n" . $json->encode($params) );
    my $subscription;
    try {
        $subscription =
          $connection->api->subscribe( "proposal" => $params )->each(
            sub {

                my ($response) = @_;
                say " current subscriptions " . keys(%subs);
                $sub = $response->body->id;
                say 'Symbol ' . $symbol;
                $subs{ $response->body->id } = $symbol;
                if ( $first && $forget_time ) {

                    $loop->delay_future( after => int( rand($forget_time) ) )
                      ->then(
                        sub {
                            say 'time forgettting ' . $sub . ' ' . $symbol;
                            $connection->api->forget( forget => $sub )
                              ->on_done(
                                sub { delete $subs{$sub}; $subscription->done; }
                              )->on_fail(
                                sub {
                                    say " unable to forget $sub";
                                    warn Dumper(@_);
                                }
                              );
                        }
                      )->retain;

                    $first = 0;
                }
            }
          )->completed()->on_fail(
            sub {
                $log->warn( "Failed to start subscription with params \n"
                      . $json->encode($params)
                      . shift->body->message );

                #retry to subscribe again with new params.
                subscribe( $connection, $connection_number )

            }
          )->on_done(
            sub {
                say "done";
                subscribe( $connection, $connection_number );
            }
          );
    }
    catch { warn $@ };
    return $future;
}

=head2 get_params

Description: Builds the send parameters for a certain contract type
Takes the following arguments 

=over 4

=item - $contract_type : string representing the type of contract  EG. 'Call', 'Put' etc

=item - $symbol : the Symbol to create the contract for EG. 'R_10', 'R_100' etc

=item - $contract_for : a HashRef of L<Binary::API::AvailableContracts> keyed by symbol and then contract type. 
see the L<contracts_for> subroutine. 

=back

Returns a HashRef of proposal attributes. 

=cut

sub get_params {
    my ( $contract_type, $symbol, $contracts_for ) = @_;
    if ( !defined( $contracts_for->{$symbol}->{$contract_type} ) ) {
        return undef;
    }
    my $contract   = $contracts_for->{$symbol}->{$contract_type};
    my $market     = $contract->market;
    my $sub_market = $contract->submarket;
    my $min        = $contract->min_contract_duration;
    my $max        = $contract->max_contract_duration;
    if ( $market eq 'forex' ) {
        ( $min, $max ) = forex_duration_adjustments(
            min        => $min,
            max        => $max,
            sub_market => $sub_market
        );
        return undef if !$min;
    }
    my ( $duration, $duration_unit ) = durations( $min, $max );

    # make sure trades don't end between 21:00 and 24:00 when
    # they are not allowed
    if ( $duration_unit ne 't' and $market ne 'synthetic_index' ) {
        my $duration_end = DateTime->now();
        my $minutes      = $duration * $multipliers{$duration_unit};
        $duration_end = $duration_end->add( minutes => $minutes );
        if ( $duration_end->hour > 21 && $duration_end->hour < 24 ) {
            return undef;
        }
    }

    my $put_call = {
        "amount"        => 10,
        "barrier"       => "+0.1",
        "basis"         => "stake",
        "contract_type" => $contract_type,
        "currency"      => "USD",
        "duration"      => $duration,
        "duration_unit" => $duration_unit,
        "symbol"        => $symbol,

    };

    my $pute_calle = {
        "amount"        => 10,
        "basis"         => "stake",
        "contract_type" => $contract_type,
        "currency"      => "USD",
        "duration"      => $duration,
        "duration_unit" => $duration_unit,
        "symbol"        => $symbol,

    };

    my $reset_put_call = {
        "amount"        => 10,
        "basis"         => "stake",
        "contract_type" => $contract_type,
        "currency"      => "USD",
        "duration"      => $duration,
        "duration_unit" => $duration_unit,
        "symbol"        => $symbol,

    };

    my $contract_params = {
        PUT      => $put_call,
        CALL     => $put_call,
        PUTE     => $pute_calle,
        CALLE    => $pute_calle,
        RESETPUT => $reset_put_call,

    };

    if ( $market eq 'forex' ) {
        delete $contract_params->{$contract_type}->{barrier};
    }
    if ( $sub_market eq 'minor_pairs' ) {
        my $current_time = DateTime->now();
        my $additional_time;
        if ( $current_time->hour > 21 && $current_time->hour < 24 ) {
             $additional_time = 3*60*60 ;  # ensure start time is out side of the restricted time
        }
        else {
            $additional_time = 1000;    # give a buffer
        }
        $contract_params->{$contract_type}->{date_start} =
          time + $additional_time;
    }

    return $contract_params->{$contract_type};
}

=head2 forex_duration_adjustments

Description: Here we try to account for the idiosyncrasies of the durations when 
dealing with Forex.  E.G. no trading on weekends and between certain times. 
Takes the following arguments as named parameters

=over 4

=item - min:   Minimum Duration as obtained from the contract type.

=item - max:  Maximum Duration as obtained from the contract type.

=item - sub_market:  The sub market associated with this contract type. 

=back

Returns an Array with adjusted min and max duration values  EG. "1d"  
IF we cant do a valid duration then the result will be [0,0]

=cut

sub forex_duration_adjustments {
    my (%attrs) = @_;

    my $min                 = $attrs{min};
    my $max                 = $attrs{max};
    my ($max_duration_type) = $attrs{max} =~ /\d+(\w)/;
    my $dt                  = DateTime->now;
    if ( $attrs{sub_market} ne 'smart_fx' ) {

        # Allow for weekends
        if ( $max_duration_type eq 'd' and $attrs{max} ne '1d' ) {
            my $dow     = $dt->day_of_week;
            my $max_day = 6 - $dow;

            # we are running on Saturday or Sunday so extend max to Friday
            if ( $dow < 1 ) { $max_day = $max_day + 6 }
            $max = ($max_day) . 'd';
        }
    }
    if ( $dt->hour > 20 && $dt->hour < 24 ) {
        return ( 0, 0 ) if $max_duration_type eq 't';
        $min = '5h';
        $max = '16h' if ( $attrs{sub_market} eq 'smart_fx' );

    }
    return ( $min, $max );
}

=head2 get_active_symbols

Description: Gets the currently active symbols via the API , this will be filtered by market types if supplied. 

Takes the following argument

=over 4

=item - $connection :  A L<Net::Async::BinaryWS> object

=item - $markets_to_use :  Arrayref of markets to get symbols from passed as an option to the script.  

=back

 returns an array of currently active symbols as string  ['R_10','R_100', ....] 

=cut

sub get_active_symbols {
    my ( $connection, $markets_to_use ) = @_;
    my $assets =
      $connection->api->active_symbols( product_type => 'basic', )->on_fail(
        sub {
            warn 'Get Active Symbols Failed  Message: ' . shift->body->message;
        }
      )->get;

    my %market_check = map { $_ => 1 } @$markets_to_use;
    my @active_symbols =
      map { $_->symbol }
      grep {
        $_->exchange_is_open
          and not $_->is_trading_suspended
          and ( !@$markets_to_use or defined( $market_check{ $_->market } ) )
      } $assets->body->symbols;

    return \@active_symbols;
}

=head2 get_contracts_for

Description: Gets the contracts available for each symbol passed to it. 
Note that we can't just use the info from C<asset_index> as the durations
are  not accurate, this is a known issue. 
Takes the following arguments

=over 4


=item - $connection :  A L<Net::Async::BinaryWS> object

=item - $symbols : an ArrayRef of currently active Symbols

=back

Returns a HashRef of L<Binary::API::AvailableContracts> keyed by symbol and then contract type

=cut

sub get_contracts_for {
    my ( $connection, $symbols ) = @_;
    my %contracts_for;
    (
        fmap0 {
            my ($symbol) = @_;
            my $response =
              $connection->api->contracts_for( contracts_for => $symbol )
              ->then(
                sub {
                    my $response = shift;
                    for my $contract ( $response->body->available ) {
                        $contracts_for{$symbol}{ $contract->contract_type } =
                          $contract;
                    }
                    return Future->done;
                }
              );
        }
        foreach => [@$symbols]
    )->get();

    return \%contracts_for;
}

=head2 durations

Description: Calculates a random duration that fits with in the min and max boundaries.
Takes the following arguments

=over 4

=item - $min : A string with the minimum duration postfixed with the type eg. 10m (types can be t, m, h, d)

=item - $max : A string with the maximum duration postfixed with the type eg. 10m (types can be t, m, h, d)

=back

Returns an Array with to items first is the number portion of the duration, second is the character defining the type.

=cut

sub durations {
    my ( $min, $max ) = @_;

    # min and max look like 1d , 2m etc
    my ( ( $min_amount, $min_unit ), ( $max_amount, $max_unit ) ) =
      map { $_ =~ /(\d+)(\w)$/ } ( $min, $max );

    if ( $min_unit eq $max_unit ) {

# $max_amount = 1 if $max_unit eq 'd';    #if we go over 1 day then it complicates the contract.
        return ( random_generator( $min_amount, $max_amount ), $min_unit );
    }

    # not handling seconds yet.
    if ( $min_unit eq 's' ) {
        $min_unit   = 'm';
        $min_amount = 1;
    }

    #how much to multiply to to get minutes (ticks not accounted for)
    my %multipliers = (
        m => 1,
        h => 60,
        d => 1440
    );
    my $min_minutes = $min_amount * $multipliers{$min_unit};
    my $max_minutes = $max_amount * $multipliers{$max_unit};

    my $random_duration = random_generator( $min_minutes, $max_minutes );

    # You can express hours in minutes but once you get to days.
    # you need to use Days or it causes errors with trades not ending
    # on a whole day.
    my $duration_unit = 'm';
    if ( $random_duration >= 1440 ) {
        $random_duration = int( $random_duration / 1440 );
        $duration_unit   = 'd';
    }
    return ( $random_duration, $duration_unit );

}

=head2 random_generator

Description: Creates random numbers between min and max,  split into a separate sub so that it 
can be overridden or mocked for testing. 
Takes the following arguments

=over 4

=item - $min : The minimum number of the random range

=item - $max : The Maximum number of the random range

=back

Returns an integer between min and max. 

=cut

sub random_generator {
    my ( $min, $max ) = @_;
    return int( rand( $max - $min ) + $min );

}

exit 0;
