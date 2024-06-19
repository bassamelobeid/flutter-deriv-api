use Object::Pad;

class BOM::Test::LoadTest::Proposal;

use Future::Utils qw(fmap0);
use Log::Any      qw($log);
use Future;
use IO::Async::Loop;
use Binary::API;
use Net::Async::BinaryWS;
use Future::AsyncAwait;
use DateTime;
use JSON::MaybeXS;
use Syntax::Keyword::Try;
use List::Util   qw(uniq);
use Array::Utils qw(intersect);

use constant TIMEOUT => 10;

=head1 NAME

C<LoadTest::Proposal> - sends dummy proposal calls to websocket to test pricing performance.

=head1 SYNOPSIS

    use LoadTest::Proposal;
    my $load_tester = LoadTest::Proposal->new(
        end_point => 'ws://127.0.0.1:5004',
        app_id => 1003,
        number_of_connections => 5,
        number_of_subscriptions => 3,
        forget_time => 20,
        test_duration => 10,
    );

     $load_tester->run_tests();


=head1 Description

Designed to create a load on Binary Pricing components via the proposal API call. It can create many connections with each connection having
many subscriptions. Subscriptions can be randomly forgotten and new ones established to take their place in order to emulate what would happen in production.
The script is not intended to have measurement ability that will need to be done externally via Datadog or other means.

=head1 Methods


=head2 new

Description: Object Constructor
Takes the following arguments as named parameters

=over 4

=item * token : The API token to use for calls, this is optional and calls are not authorized by default.

=item * app_id : The application id to use for API calls.

=item * end_point : The end point to send calls to. E.G. C<ws://127.0.0.1:5004> for QA local host.

=item * number_of_connections :  The number of  connections to establish.

=item * number_of_subscriptions : The number of subscriptions per connection.

=item * forget_time : The upper bound of the random time in seconds to forget subscriptions.

=item * test_duration : The number of seconds to run the test for before exiting.

=item * markets :  An ArrayRef of market names to use in tests EG. "forex", "synthetic_index" etc. .  If not supplied defaults to all.

=back

Returns a L<LoadTest::Proposal> Object.

=cut

field %args;
field $json;
field $active_symbols;
field %subs;
field $contracts_for : writer;
field $multipliers;
field $loop;

BUILD {
    (%args) = @_;
    $json        = JSON::MaybeXS->new(pretty => 1);
    $multipliers = {
        s => 1,
        m => 1,
        h => 60,
        d => 1440
    };
    $loop = IO::Async::Loop->new;
}

=head2 run_tests

Description:  Starts the test run, using the arguments passed in by the objects constructor.
Takes  no arguments

Returns integer 1 when complete

=cut

method run_tests () {

    my $main_connection =
        $self->create_connection($args{end_point}, $args{app_id}, $args{token});

    $active_symbols = $self->get_active_symbols($main_connection, $args{markets});
    $log->debug("Active Symbols \n" . "@$active_symbols");
    if (!@$active_symbols) { die "No Active Symbols Available" }

    $contracts_for = $self->get_contracts_for($main_connection, $active_symbols);

    # Will cause script to exit when test_duration is reached.
    my $test_length_timer = $self->test_length_timer($args{test_duration});

    # Main Loop starts up the number of connections to the Websocket API.
    my $main_loop = fmap0 {
        try {
            my ($connection_number) = @_;
            $self->create_subscriptions($connection_number);
        } catch ($e) {

            $log->warn('Failed ' . $e);
            return Future->done;
        }
    }
    foreach        => [(1 .. $args{number_of_connections})],
        concurrent => $args{number_of_connections};
    Future->wait_all($main_loop, $test_length_timer)->get();

    return 1;

}

=head2 test_length_timer

Description: Gets a future to control the length the script runs for.
If $test_duration is false it will return an unlimited future that will never be done.

Takes the following argument

=over 4

=item * C<$test_duration> - The amount of time to run the script for in seconds, (optional).

=back

Returns a L<Future>

=cut

method test_length_timer ($test_duration = 0) {
    my $test_run_length;
    if ($test_duration) {
        $test_run_length = $loop->delay_future(after => $test_duration)->on_done(sub { $log->info('finished after ' . $test_duration); });
    } else {
        $test_run_length = $loop->new_future;    # A Future that will never be done.
    }
    return $test_run_length;
}

=head2 create_subscriptions

Description: Creates a connection then starts the number of subscriptions, passed.
as the -s parameter to the script.
Takes the following argument.

=over 4

=item  $connection_number : the counter for the connection number.

=back

Returns a L<Future>

=cut

method create_subscriptions ($connection_number) {
    $log->info('Connection Number ' . $connection_number);
    my $connection =
        $self->create_connection($args{end_point}, $args{app_id}, $args{token});
    return fmap0 {
        try {
            $self->subscribe($connection, $connection_number);
        } catch ($e) {
            $log->warn('Creating a subscription Failed ' . $e);
            return Future->done;
        }
    }
    foreach        => [(1 .. $args{number_of_subscriptions})],
        concurrent => $args{number_of_subscriptions};

}

=head2 create_connection

Description: Responsible for creating the connections, times out if longer than TIMEOUT seconds.
will attempt to authorize if a token is passed via the -t parameter to the script.

=over 4

=item - $endpoint :  Something like C<ws://127.0.0.1:5004>

=item - $app_id:   the application ID to use in requests.

=item - $token:


=back

Returns a L<Net::Async::BinaryWS>

=cut

method create_connection ($end_point, $app_id, $token) {

    $loop->add(
        my $connection = Net::Async::BinaryWS->new(
            endpoint => $end_point,
            app_id   => $app_id,
        ));
    Future->wait_any(
        $connection->connected->then(
            sub {
                if ($token) {
                    return $connection->api->authorize(authorize => $token)->on_fail(
                        sub {
                            $log->warn('Authorize Failed ' . shift->body->message);
                            Future->done;
                        });

                } else {
                    return Future->done;
                }

            }
        ),
        $loop->timeout_future(after => TIMEOUT)->on_fail(
            sub {
                die("timeout connecting to $end_point");
            })
    )->transform(
        done => sub {
            $connection;
        })->get;

    return $connection;
}

=head2 durations

Description: Calculates a random duration that fits with in the min and max boundaries.
Takes the following arguments

=over 4

=item - $min : A string with the minimum duration postfixed with the type eg. 10m (types can be t, m, h, d)

=item - $max : A string with the maximum duration postfixed with the type eg. 10m (types can be t, m, h, d)

=back

Returns an Array with two items first is the number portion of the duration, second is the character defining the type.

=cut

method durations ($min, $max) {

    # min and max look like 1d , 2m etc
    my (($min_amount, $min_unit), ($max_amount, $max_unit)) =
        map { $_ =~ /(\d+)(\w)$/ } ($min, $max);

    if ($min_unit eq $max_unit) {
        return ($self->random_generator($min_amount, $max_amount), $min_unit);
    }

    # Anything past here the max and min duration types are different.
    #
    my $duration_unit = 'm';    #default duration unit

    if ($min_unit eq 's') {     # The only unit max can be field to be minutes or larger.
        $min_unit   = 'm';
        $min_amount = 1;
    } elsif ($min_unit eq 't' and $max_unit eq 's') {    # Only thing that can be smaller than a second is a tick
        $min_unit      = 's';
        $min_amount    = 1;
        $duration_unit = 's';
    } elsif ($min_unit eq 't') {                         # min is type ticks but max is not seconds so must be minutes or greater.
        $min_unit   = 'm';
        $min_amount = 1;
    }

    # standardize durations
    my $min_standardized = $min_amount * $multipliers->{$min_unit};
    my $max_standardized = $max_amount * $multipliers->{$max_unit};

    my $random_duration = $self->random_generator($min_standardized, $max_standardized);

    # You can express hours in minutes but once you get to days
    # you need to use Days or it causes errors with trades not ending
    # on a whole day.
    if ($random_duration >= 1440) {
        $random_duration = int($random_duration / 1440);
        $duration_unit   = 'd';
    }
    return ($random_duration, $duration_unit);

}

=head2 random_generator

Description: Creates random numbers between min and max, split into a separate sub so that it
can be overridden or mocked for testing.
Takes the following arguments

=over 4

=item - $min : The minimum number of the random range

=item - $max : The Maximum number of the random range

=back

Returns an integer between min and max.

=cut

method random_generator ($min, $max) {
    return int(rand($max - $min) + $min);

}

=head2 get_contracts_for

Description: Gets the contracts available for each symbol passed to it.
Note that we can't just use the info from C<asset_index> as the durations
are not accurate, this is a known issue.
Takes the following arguments

=over 4


=item - $connection :  A L<Net::Async::BinaryWS> object

=item - $symbols : an ArrayRef of currently active Symbols

=back

Returns a HashRef of L<Binary::API::AvailableContracts> keyed by symbol and then contract type

=cut

method get_contracts_for ($connection, $symbols) {
    my %contracts_for;

    my $contracts_for_requests = fmap0 {
        my ($symbol) = @_;
        my $response = $connection->api->contracts_for(contracts_for => $symbol)->then(
            sub {
                my $response = shift;
                for my $contract ($response->body->available) {
                    $contracts_for{$symbol}{$contract->contract_type} = $contract;
                }
                return Future->done;
            });
    }
    foreach        => [@$symbols],
        concurrent => 1;
    $contracts_for_requests->get();

    return \%contracts_for;
}

=head2 get_active_symbols

Description: Gets the currently active symbols via the API, this will be filtered by market types if supplied.

Takes the following arguments

=over 4

=item - $connection :  A L<Net::Async::BinaryWS> object

=item - $markets_to_use :  Arrayref of markets to get symbols from passed as an option to the script.

=back

Returns an array of currently active symbols as string  ['R_10','R_100', ....]

=cut

method get_active_symbols ($connection, $markets_to_use) {
    my $assets = $connection->api->active_symbols(
        product_type => 'basic',
    )->on_fail(
        sub {
            $log->warn('Get Active Symbols Failed  Message: ' . shift->body->message);
        })->get;

    my %market_check = map { $_ => 1 } @$markets_to_use;
    my @active_symbols =
        map  { $_->symbol }
        grep { $_->exchange_is_open and not $_->is_trading_suspended and (not scalar(@$markets_to_use) or defined($market_check{$_->market})) }
        $assets->body->symbols;

    return \@active_symbols;
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
If we cant do a valid duration then the result will be [0,0]

=cut

method forex_duration_adjustments (%attrs) {

    my $min                 = $attrs{min};
    my $max                 = $attrs{max};
    my ($max_duration_type) = $attrs{max} =~ /\d+(\w)/;
    my $dt                  = DateTime->now;
    if ($attrs{sub_market} ne 'forex_basket') {

        # Allow for weekends
        if ($max_duration_type eq 'd' and $attrs{max} ne '1d') {
            my $dow     = $dt->day_of_week;
            my $max_day = 6 - $dow;

            # we are running on Saturday or Sunday so extend max to Friday
            if ($dow < 1) { $max_day = $max_day + 6 }
            $max = ($max_day) . 'd';
        }
    }
    if ($dt->hour > 20 && $dt->hour < 24) {
        return (0, 0) if $max_duration_type eq 't';
        $min = '5h';
        $max = '16h' if ($attrs{sub_market} eq 'forex_basket');

    }
    return ($min, $max);
}

=head2 get_params

Description: Builds the send parameters for a certain contract type.
Takes the following arguments

=over 4

=item - $contract_type : string representing the type of contract  EG. 'Call', 'Put' etc.

=item - $symbol : the Symbol to create the contract for EG. 'R_10', 'R_100' etc.

=item - $contract_for : a HashRef of L<Binary::API::AvailableContracts> keyed by symbol and then contract type.
see the L<contracts_for> subroutine.

=back

Returns a HashRef of proposal attributes.

=cut

method get_params ($contract_type, $symbol) {

    if (!defined($contracts_for->{$symbol}->{$contract_type})) {
        return undef;
    }

    my $contract = $contracts_for->{$symbol}->{$contract_type};
    return $self->get_params_mult_up_down($contract) if $contract_type eq 'MULTUP' or $contract_type eq 'MULTDOWN';
    my $market     = $contract->market;
    my $sub_market = $contract->submarket;
    my $min        = $contract->min_contract_duration;
    my $max        = $contract->max_contract_duration;
    if ($market eq 'forex') {
        ($min, $max) = $self->forex_duration_adjustments(
            min        => $min,
            max        => $max,
            sub_market => $sub_market
        );
        return undef if !$min;
    }
    my ($duration, $duration_unit) = $self->durations($min, $max);

    my $put_call = {
        amount        => 10,
        barrier       => "+0.1",
        basis         => "stake",
        contract_type => $contract_type,
        currency      => "USD",
        duration      => $duration,
        duration_unit => $duration_unit,
        symbol        => $symbol,

    };

    my $pute_calle = {
        amount        => 10,
        basis         => "stake",
        contract_type => $contract_type,
        currency      => "USD",
        duration      => $duration,
        duration_unit => $duration_unit,
        symbol        => $symbol,
    };

    my $contract_params = {
        PUT   => $put_call,
        CALL  => $put_call,
        PUTE  => $pute_calle,
        CALLE => $pute_calle,
    };

    if ($market =~ /^(forex|commodities|indices)$/) {
        delete $contract_params->{$contract_type}->{barrier};
    }
    if ($sub_market eq 'minor_pairs') {
        my $current_time = DateTime->now();
        my $additional_time;
        if ($current_time->hour >= 21 && $current_time->hour <= 23) {
            # ensure start time is out side of the restricted time
            $additional_time = 3 * 60 * 60;
        } else {
            $additional_time = 1000;    # give a buffer
        }
        $contract_params->{$contract_type}->{date_start} = time + $additional_time;
    }

    return $contract_params->{$contract_type};
}

method get_params_mult_up_down ($contract) {
    return {
        amount        => 1 + int(rand(200)),
        basis         => "stake",
        contract_type => $contract->contract_type,
        currency      => "USD",
        duration_unit => "s",
        multiplier    => $contract->data->{multiplier_range}->[int(rand(scalar($contract->data->{multiplier_range}->@*)))],
        product_type  => "basic",
        symbol        => $contract->underlying_symbol,
    };
}

=head2 subscribe

Description: Creates one subscription to a proposal,  subscriptions will randomly be forgotten if the forget_time attribute was set,  when they do
another subscription will be created and the same will happen if an error occurs.  Since failed and forgotten
subscriptions are recreated there should be a constant number of subscriptions during a run.
Takes the following arguments

=over 4

=item - $connection :  An established L<Net::Async::BinaryWS> connection

=item - $connection_number : A counter to indicate which connection this is on.

=back

Returns a L<Future>

=cut

method subscribe ($connection, $connection_number) {
    my $sub;
    my $first  = 1;
    my $future = $loop->new_future;
    my $symbol =
        $active_symbols->[int(rand(scalar($active_symbols->@*)))];
    # TODO modify & cache this types accoring to the returned value
    my @possible_contract_types  = qw(PUT CALL PUTE CALLE MULTUP MULTDOWN);
    my @available_contract_types = keys $contracts_for->{$symbol}->%*;
    #$log->info("available contract type @available_contract_types");
    my @contract_types = intersect(@possible_contract_types, @available_contract_types);
    die "possible available contract types is none for symbol $symbol" unless @contract_types;
    my $contract_type = $contract_types[int(rand(@contract_types))];
    $log->info("Subscribing to $symbol using using connection number $connection_number contract type $contract_type");
    my $params      = $self->get_params($contract_type, $symbol);
    my $retry_count = 0;

    while (!$params && $retry_count < 5) {
        $symbol        = $active_symbols->[int(rand($active_symbols->@*))];
        $contract_type = $contract_types[int(rand(@contract_types))];
        $params        = $self->get_params($contract_type, $symbol);
        $log->debug(" Trying to get params for $contract_type , $symbol for the $retry_count time");
        $retry_count++;
    }
    die "Cannot get valid params for $contract_type, $symbol after retry $retry_count times\n" unless $params;
    $log->debug("Subscribing with \n" . $json->encode($params));
    my $subscription;
    try {
        $subscription = $connection->api->subscribe("proposal" => $params)->each(
            sub {
                my ($response) = @_;

                $log->info("current subscriptions " . keys(%subs));
                $sub = $response->body->id;
                $log->info('Symbol ' . $symbol);
                $subs{$response->body->id} = $symbol;
                if ($first && $args{forget_time}) {

                    $loop->delay_future(after => int(rand($args{forget_time})))->then(
                        sub {
                            $log->info('time forgettting ' . $sub . ' ' . $symbol);
                            $connection->api->forget(forget => $sub)->on_done(sub { delete $subs{$sub}; $subscription->done; })->on_fail(
                                sub {
                                    $log->warnf(" unable to forget $sub: %s", \@_);
                                });
                        })->retain;

                    $first = 0;
                }
            }
        )->completed()->on_fail(
            sub {
                $log->warnf("Failed to start subscription: <%s> with params\n%s", shift->body->message, $json->encode($params));

                #retry to subscribe again with new params.
                $self->subscribe($connection, $connection_number);

            }
        )->on_done(
            sub {
                $log->info("done");
                $self->subscribe($connection, $connection_number);
            });
    } catch ($e) {
        $log->warn($e);
    };
    return $future;
}

method all_markets {
    my $connection = $self->create_connection($args{end_point}, $args{app_id}, $args{token});
    my $assets     = $connection->api->active_symbols(
        product_type => 'basic',
    )->on_fail(
        sub {
            $log->warn('Get Active Symbols Failed  Message: ' . shift->body->message);
        })->get;
    my @markets = sort { $a cmp $b } uniq map { $_->market } grep { $_->exchange_is_open and not $_->is_trading_suspended } $assets->body->symbols;

    return @markets;

}

1;
