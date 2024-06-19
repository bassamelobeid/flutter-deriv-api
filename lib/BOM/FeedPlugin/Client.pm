package BOM::FeedPlugin::Client;

use strict;
use warnings;

=head1 NAME
BOM::FeedPlugin::Client
=head1 SYNOPSIS
Create script which contains
    BOM::FeedPlugin::Client->new->run->get;
and this will run until either shut down or an error occurs.
=head1 DESCRIPTION
This is daemon that connects and subscribe to the feed source remote redis, receives ticks,
and invoke `on_tick` for every registered plugin. 
There is no plugin enabled by default. Make sure you enable the desired plugin upon starting the service.
=head1 REQUIRED METHODS
 I<source> method, is required and it will determine which redis the client will connect to.
=cut

use base qw(IO::Async::Notifier);

use Carp;

use Syntax::Keyword::Try;
use Encode;
use JSON::MaybeUTF8 qw(:v1);
use POSIX           qw(:errno_h);
use BOM::Config::Redis;
use Time::HiRes;
use RedisDB;
use YAML::XS qw/LoadFile/;
use Log::Any qw($log);
use Future;
use Net::Async::Redis;

sub source       { return shift->{source} }
sub redis_config { return shift->{redis_config} }
sub plugins      { return shift->{plugins} //= [] }

=head2 create_redis
Create a redis read connection to "redis-feed-master" by getting redis config file with --config=<redis_config> flag.
=cut

sub create_redis {
    my ($config_name, $redis_access_type) = @_;
    my $redis_conf = LoadFile($config_name)->{$redis_access_type};

    my $redis_uri      = "redis://" . $redis_conf->{host} . ":" . $redis_conf->{port};
    my $redis_password = $redis_conf->{password};

    my $redis = Net::Async::Redis->new(
        $redis_uri
        ? (
            uri  => $redis_uri,
            auth => $redis_password
            )
        : ());

    return $redis;
}

sub plugins_running {
    my $self = shift;
    unless ($self->{plugins_running}) {
        push @{$self->{plugins_running}}, (split '::', ref($_))[-1] for ($self->plugins->@*);
    }
    return $self->{plugins_running};
}

sub _failure_future {
    my $self = shift;
    return $self->{failure} //= $self->loop->new_future->set_label('Client failure notification');
}

sub _init {
    my ($self, $params) = @_;

    $self->{source}       = delete $params->{source};
    $self->{redis_config} = delete $params->{redis_config};
    defined $self->{source}       or croak "Required 'source'";
    defined $self->{redis_config} or croak "Required 'redis_config'";

    $self->SUPER::_init(@_);

    return;

}

sub _process_incoming_messages {
    my ($self, $tick) = @_;

    try {
        # Update plugins attached and enabled.
        $_->on_tick($tick) for ($self->plugins->@*);
    } catch ($e) {
        $log->errorf('Exception raised while processing quote from Redis: %s', $e);
        $self->_failure_future->fail($e, '_process_incoming_messages') unless $self->_failure_future->is_ready;
    }
    return;
}

sub run {
    my $self         = shift;
    my $source       = $self->source;
    my $redis_config = $self->redis_config;

    my $redis = create_redis($redis_config, $source);

    $self->add_child($redis);

    my $run_future = $redis->connect->then(
        sub {
            $redis->psubscribe('TICK_ENGINE::*');
        }
    )->then(
        sub {
            my ($sub) = @_;
            $log->debugf('Subscribed to Redis endpoint [%s]', $redis->endpoint);

            my $payload_source = $sub->events->map('payload')->decode('UTF-8')->decode('json');
            $payload_source->each($self->curry::weak::_process_incoming_messages);    ## no critic (Freenode::DeprecatedFeatures)
            return $payload_source->completed->on_fail(
                sub {
                    my $error = shift;
                    $log->errorf('Exception raised while processing quote from Redis: %s', $error);
                });

        });

    return Future->wait_any($run_future, $self->_failure_future);
}

1;

=head1 MESSAGE FORMAT
All ticks passed on_tick for plugins to use them have the same structure. Here's the list of fields that may be defined in the tick message:
=over 4

=item B<epoch>

=item B<symbol>

=item B<quote>

=item B<bid>

=item B<ask>

=item B<source>

=back
