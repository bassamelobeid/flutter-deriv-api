package BOM::Test::WebsocketAPI::Publisher;

no indirect;

use strict;
use warnings;
use feature 'state';

=head1 NAME

BOM::Test::WebsocketAPI::Publisher - Responsible to publish values used for testing

=head1 SYNOPSIS

    $publisher = BOM::Test::WebsocketAPI::Publisher;

    $publisher->ticks(qw(R_100 R_50);

    diag explain $publisher->published;

=head1 DESCRIPTION

To publish data and access to the published data, be it to a database or Redis.
We can have only one instance of C<publisher> running, because the test database
will be shared between instances, and that can't work with expected values.

=cut

use parent qw(IO::Async::Notifier);

use Log::Any qw($log);
use List::Util qw(shuffle uniq reduce first);
use List::MoreUtils qw(first_index);
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Test::More;
use curry;
use Try::Tiny;
use Future::Utils qw(fmap0);

use BOM::Test;
use Binary::API::Mapping::Response;
use BOM::Test::WebsocketAPI::Redis qw/shared_redis ws_redis_master redis_transaction/;
use BOM::Test::WebsocketAPI::Data qw( publish_data publish_methods );
use BOM::Test::WebsocketAPI::Parameters qw( test_params );

our %handlers;

# Returns a singleton, there must be only one instance of publisher at all times
sub new {
    return our $ONE_TRUE_LOOP ||= shift->really_new(@_);
}

sub really_new {
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    return $self;
}

sub _add_to_loop {
    my ($self) = @_;
    # Start publishing
    return $self->redis_timer;
}

=head2 published

Stores a list of expected responses (L<Binary::API::Mapping::Response>)
generated based on the published values to Redis or DB, per method.

=cut

sub published { return shift->{published} //= {} }

=head2 ryu

Utility class used for timers, created on demand.

=cut

sub ryu {
    my $self = shift;

    return $self->{ryu} if exists $self->{ryu};

    $self->add_child(my $ryu = Ryu::Async->new);

    return $self->{ryu} = $ryu;
}

=head2 publisher_state

Returns a hashref that keeps the publisher state, used to save information
across different calls to L<on_timer>.

=cut

sub publisher_state { return shift->{publisher_state} //= {} }

=head1 METHODS

=head2 pause

Pauses publishing for a given method.

=cut

sub pause {
    my ($self, $method) = @_;

    return $self->{paused}{$method} = 1;
}

=head2 resume

Resumes publishing for a given method.

=cut

sub resume {
    my ($self, $method) = @_;

    return delete $self->{paused}{$method};
}

=head2 is_paused

Returns true if publishing is paused for a given method.

=cut

sub is_paused {
    my ($self, $method) = @_;

    return exists $self->{paused}{$method};
}

=head2 handler

Defines a publish handler for a type of value to be published to Redis. The
publish handler will receive a request to be published every second.
The request is specified in the client side, where L<publish> is called.

Note that this is different from the function that makes those requests to
publish.

=cut

sub handler {
    my ($name, $code) = @_;

    return $handlers{$name} = $code;
}

=head2 website_status handler

The code that handles publishing website_status into redis.

=cut

handler website_status => sub {
    my ($self, $key, $type, $payload) = @_;

    return ws_redis_master->then(
        $self->$curry::weak(
            sub {
                my ($self, $redis) = @_;

                Future->needs_all($redis->set('NOTIFY::broadcast::is_on', 1), $redis->set('NOTIFY::broadcast::state', encode_json_utf8($payload)),)
                    ->then(
                    sub {
                        $self->publish($key, $type, $payload, ws_redis_master);
                    });
            }))->retain;
};

=head2 tick handler

The code that handles publishing ticks into redis (and update ticks history).

=cut

handler tick => sub {
    my ($self, $key, $type, $payload) = @_;

    my $tick = $self->update_ticks_history($payload);

    return $self->publish($key, $type => $tick) if $tick;

    return undef;
};

=head2 transaction handler

The code that handles publishing transaction and balance to Redis.

=cut

handler transaction => sub {
    my ($self, $key, $type, $transaction) = @_;

    my $currency = $transaction->{currency_code};
    my $loginid  = delete $transaction->{loginid};

    return $self->publish($key, $type, $transaction, redis_transaction)->on_done(
        $self->$curry::weak(
            sub {
                my ($self) = @_;
                # balance (each transaction update also updates the balance)
                $self->add_to_published(
                    balance => {
                        balance  => $transaction->{balance_after},
                        currency => $currency,
                        loginid  => $loginid,
                    });
            }));
};

=head2 on_timer

Called every second. Creates simulated events for mock data received from
C<publish_data> in C<BOM::Test::WebsocketAPI::Data>.

=cut

sub on_timer {
    my ($self) = @_;

    for my $type (publish_methods()) {
        next if exists $self->{paused}{$type};
        # The mock publish data is lazy loaded
        my $data = publish_data($type) or next;

        for my $key (keys $data->%*) {
            for my $payload ($data->{$key}->@*) {
                if (exists $handlers{$type}) {
                    $handlers{$type}->($self, $key, $type => $payload);
                } else {
                    $self->publish($key, $type => $payload);
                }
            }
        }
    }

    return undef;
}

=head2 publish

Publishes the given response to Redis, saving the expected response
in C<published>

=cut

sub publish {
    my ($self, $channel, $method, $payload, $redis_client) = @_;

    $redis_client //= shared_redis;

    $log->debugf('Publishing a %s, %s', $method, join ", ", map { $_ . ': ' . $payload->{$_} } sort keys $payload->%*);

    return $redis_client->then(
        $self->$curry::weak(
            sub {
                my ($self, $redis) = @_;
                $redis->publish($channel => encode_json_utf8($payload))->on_done(
                    sub {
                        $self->add_to_published($method, $payload);
                    });
            }))->retain;
}

=head2 add_to_published

Pushes the expected response based on the payload that we published to Redis.

=cut

sub add_to_published {
    my ($self, $method, $payload) = @_;

    my $response = $self->published_to_response($method => $payload);

    push $self->published->{$method}->@*, $response;

    return undef;
}

# Global Variable used to map what is sent to what we expect when they differ.
my $published_to_response_mapping = {
    transaction => {
        rename_fields => {
            action_type             => 'action',
            id                      => 'transaction_id',
            financial_market_bet_id => 'contract_id',
            balance_after           => 'balance',
            payment_remark          => 'longcode',
        },
    },
    proposal => {
        delete_fields => {
            theo_probability => 1,
            price_daemon_cmd => 1,
            rpc_time         => 1,
            payout           => 1
        },
    },
};

=head2 published_to_response

Map the published fields to the expected response from the API

=cut

sub published_to_response {
    my ($self, $method, $published, $options) = @_;

    my $frame = {
        echo_req => {
            # Don't know what to put in here
            $method => 'placeholder',
        },
        msg_type => $method,
        ($options // {})->%*,
    };

    for my $field (keys $published->%*) {
        my $mapping        = $published_to_response_mapping->{$method};
        my $response_field = $field;
        if ($mapping->{rename_fields}->{$field}) {
            $response_field = $published_to_response_mapping->{$method}->{rename_fields}->{$field};
        }
        if ($mapping->{delete_fields}->{$field}) {
            next;
        }
        $frame->{$method}->{$response_field} = $published->{$field};
    }

    return Binary::API::Mapping::Response->new($frame);
}

=head2 redis_timer

Calls C<< $self->on_timer >> every second.

=cut

sub redis_timer {
    my ($self) = @_;

    return $self->{redis_timer}
        if defined $self->{redis_timer}
        and not $self->{redis_timer}->completed->is_ready;

    $self->{redis_timer} = $self->ryu->timer(interval => 1)->each($self->$curry::weak(sub { shift->on_timer }));    ## no critic DeprecatedFeatures

    return $self->{redis_timer};
}

=head2 update_ticks_history

Update the history of ticks in database with newly generated ticks.
Returns the tick if it's new, C<undef> otherwise.

=cut

sub update_ticks_history {
    my ($self, $tick_to_publish) = @_;

    my $state  = $self->publisher_state;
    my $symbol = $tick_to_publish->{symbol};

    my $tick = {$tick_to_publish->%*};
    my $current_history = $state->{ticks_history}{$symbol} // Binary::API::Mapping::Response->new({
            echo_req => {
                ticks_history => $symbol,
            },
            msg_type => 'history',
            history  => {(
                    map { (times => $_->times, prices => $_->prices) }
                    grep { $_->underlying->symbol eq $symbol } test_params()->{ticks_history}->@*
                )
            },
        });

    my @history_times  = ($current_history ? $current_history->body->times->@*  : ());
    my @history_prices = ($current_history ? $current_history->body->prices->@* : ());
    return if first { $_ eq $tick->{epoch} } @history_times;

    my $history = {
        times  => [@history_times,  $tick->{epoch}],
        prices => [@history_prices, $tick->{quote}],
    };
    $state->{ticks_history}->{$symbol} = $self->published_to_response(
        history => $history,
        {echo_req => {ticks_history => $symbol}});

    my $published_history = $self->published->{history} //= [];
    my $published_index = first_index { $_->body->symbol eq $symbol } $published_history->@*;
    splice $published_history->@*, $published_index, 1 if $published_index > -1;
    push $published_history->@*, $state->{ticks_history}->{$symbol};

    return $tick_to_publish;
}

1;
