package Binary::WebSocketAPI::v3::Subscription;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription - role class for subscriptions handled by Redis

=head1 DESCRIPTION

This module is the common interface for subscription-related tasks such as transactions and pricing

=cut

use feature qw(state);
use Future;
use Future::Mojo;
use curry::weak;

use JSON::MaybeUTF8 qw(:v1);
use Binary::WebSocketAPI::v3::SubscriptionManager;
use Scalar::Util qw(blessed weaken);
use Log::Any qw($log);
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);
use Moo::Role;

=head1 ATTRIBUTES

=head2 status

A L<Future> representing the subscription state - resolved if the subscription
is active.

    $subscription->status->is_done

=cut

has status => (
    is       => 'rw',
    weak_ref => 1,
);

=head2 c

  a L<Mojolicious::Controller> object.

=cut

has c => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

=head2 args

=cut

has args => (
    is       => 'ro',
    required => 1,
);

=head2 uuid

=cut

my $RAND;

BEGIN {
    open $RAND, "<", "/dev/urandom" or die "Could not open /dev/urandom : $!";    ## no critic (InputOutput::RequireBriefOpen)
}

has uuid => (
    is      => 'ro',
    default => sub {
        return generate_uuid_string();
    });

# TODO used temporarily for webstatus subscription. Should be moved to `has uuid` `default` after webstatus subscription also migrated to subscription object.
sub generate_uuid_string {
    local $/ = \16;
    return join "-", unpack "H8H4H4H4H12", (scalar <$RAND> or die "Could not read from /dev/urandom : $!");
}

=head2 channel

=cut

has channel => (is => 'lazy');

=head1 METHODS

=cut

=head2 process

Decode, and handle incoming redis messages.

=cut

sub process {
    my ($self, $message) = @_;
    return try {
        my $data = decode_json_utf8($message);
        $data = $self->handle_error($data->{error}, $message, $data) if exists $data->{error};
        return undef unless $data;
        return $self->handle_message($data);
    }
    catch {
        $log->errorf("Failure processing Redis subscription message:  %s from original message %s, module %s, channel %s",
            $_, $message, $self->class, $self->channel);
    }
}

requires qw(handle_message subscription_manager _unique_key);

=head2 handle_message

Process the redis messages

=cut

=head2 subscription_manager

The SubscriptionManager instance that will manage this worker

=cut

# The method _unique_key is used to find a subscription. Class name + _unique_key will be a unique index of the subscription objects.

=head2 class

The whole class name of the object.

=cut

sub class {
    my $self = shift;
    return blessed($self) || $self;
}

=head2 abbrev_class

The abbreviation class name

=cut

sub abbrev_class {
    my $self  = shift;
    my $class = $self->class;
    $class =~ s/^Binary::WebSocketAPI::v3::Subscription:://;
    return $class;
}

=head2

the name that will be used in stats_* function

=cut

has stats_name => (is => 'lazy');

sub _build_stats_name {
    my ($self) = @_;
    $self->class =~ /(\w+)$/;
    my $package = lc($1);
    return "bom_websocket_api.v_3.${package}_subscriptions";
}

=head2 handle_error

process the error

=cut

sub handle_error {
    my ($self, $err, $msg) = @_;

    if ($err->{code} eq 'TokenDeleted') {
        if ($self->c->stash->{token} eq $err->{token}) {
            # this cannot be "use", because of our class structure
            require Binary::WebSocketAPI::v3::Wrapper::Authorize;
            Binary::WebSocketAPI::v3::Wrapper::Authorize::logout_success($self->c);
        }
        return;
    }

    $log->errorf("error happened when processing message: %s from %s, module %s, channel %s", $err->{code}, $msg, $self->class, $self->channel);
    return undef;
}

=head2 subscribe

    subscribe to the streamer . Takes the following arguments as parameters :

=over 4

=item callback => sub {}

A sub that will be called after successful subscription

=back

Returns the status L<Future> object

=cut

sub subscribe {
    my ($self, $callback) = @_;

    $self->status($self->subscription_manager->subscribe($self)) unless $self->status;
    return $self->status unless $callback;

    my $wrapped_cb = sub {
        my $self = shift;
        try {
            $callback->($self);
        }
        catch {
            $log->warnf("callback invocation error during redis subscription to class %s, channel %s: $_", $self->class, $self->channel);
        };
    };
    $self->status->on_done($self->$curry::weak($wrapped_cb));
    $log->warnf("Too many callbacks in class %s channel %s queue, possible redis connection issue", $self->class, $self->channel)
        if (($self->status->{callbacks} // [])->@* > 1000);
    return $self->status;
}

=head2 unsubscribe

unsubscribe the channel

=cut

sub unsubscribe {
    my $self = shift;
    return $self->subscription_manager->unsubscribe($self);
}

=head2 already_registered

Check there is a subscription on that channel with same key information.

Returns registered subscription object or false

=cut

sub already_registered {
    my $self           = shift;
    my $channels_stash = __PACKAGE__->_channels_stash($self->c);
    return $channels_stash->{$self->abbrev_class}{$self->_unique_key};
}

=head2 register

Register the subscription into stash data

=cut

sub register {
    my $self               = shift;
    my $already_registered = $self->already_registered;
    return $already_registered if $already_registered;
    my $channels_stash = __PACKAGE__->_channels_stash($self->c);
    # This place is the only place that store a strong reference of the subscription object.
    # References in Anywhere else should be weakened or should be in lexical scope.
    # Deleting subscription object reference from this place means destroying this object.
    $channels_stash->{$self->abbrev_class}{$self->_unique_key} = $self;
    my $uuid_channel_stash = __PACKAGE__->_uuid_channel_stash($self->c);
    weaken($uuid_channel_stash->{$self->uuid} = $self);
    return $self;
}

=head2 unregister

Remove the subscription from stash data

=cut

sub unregister {
    my $self = shift;
    return undef unless $self->c;
    my $channels_stash = __PACKAGE__->_channels_stash($self->c);
    delete $channels_stash->{$self->abbrev_class}{$self->_unique_key};
    delete $channels_stash->{$self->abbrev_class} unless %{$channels_stash->{$self->abbrev_class} // {}};
    delete __PACKAGE__->_uuid_channel_stash($self->c)->{$self->uuid};
    return $self;
}

=head1 METHODS - Construction/destruction

=head2 BUILD

record some stats

=cut

sub BUILD {
    my $self = shift;
    stats_inc($self->stats_name . '.instances');
    return $self;
}

=head2 DEMOLISH

On cleanup, will notify the manager in case it needs to unsubscribe.

=cut

sub DEMOLISH {
    my ($self, $global) = @_;

    return undef if $global;
    $log->tracef("Destroying the worker %s channel %s", $self->class, $self->channel);
    stats_dec($self->stats_name . '.instance');
    delete __PACKAGE__->_uuid_channel_stash($self->c)->{$self->uuid} if $self->c;
    return undef unless $self->status;
    $self->unsubscribe();
    return undef;
}

=head1 class methods

=cut

# _channels_stash
#The hash that store the subscription objects with the key _uinque_key.
#It is 2 layer hash. The first key is abbrev_class name, the second one is the unique key _unique_key to avoid duplicate subscription. Different subclass has different algorithm for the key.

sub _channels_stash {
    my ($class, $c) = @_;
    my $stash = $c->stash;
    return $stash->{channels} //= {};
}

# the hash of subscription whose keys are uuids
sub _uuid_channel_stash {
    my ($class, $c) = @_;
    my $stash = $c->stash;
    return $stash->{uuid_channel} //= {};
}

=head2 get_by_class

Get the subscriptions that is the object of special class
Takes the following arguments:

=over 4

=item class

=item c is a Mojolicious::Controller

=back

Returns all subscription objects which belongs to given class.

=cut

sub get_by_class {
    my ($class, $c) = @_;
    die "need a 'c' object" unless $c;
    my $abbrev_class   = $class->abbrev_class;
    my $channels_stash = $class->_channels_stash($c);
    return (values %{$channels_stash->{$abbrev_class}});
}

=head2 get_by_uuid

get the subscription given a special uuid.

Takes the following arguments:

=over 4

=item class

=item c -- Mojolicious::Controller

=item uuid -- the uuid of subscription object

=back

Returns the subscription object whose uuid is the given value or undef if no such object

=cut

sub get_by_uuid {
    my ($class, $c, $uuid) = @_;
    die "need c and uuid" unless $c && $uuid;
    return $class->_uuid_channel_stash($c)->{$uuid};
}

=head2 unregister_by_uuid

unregister a subscription given a special uuid

It takes the following arguments:

=over 4

=item class

=item c -- Mojolicious::Controller

=item uuid -- uuid of subscription object

Returns uuid if found and unregistered the subject, else undef

=back

=cut

sub unregister_by_uuid {
    my ($class, $c, $uuid) = @_;
    if (my $subscription = $class->get_by_uuid($c, $uuid)) {
        $subscription->unregister;
        return $uuid;
    }
    return undef;
}

=head2 unregister_class

Unregister all subscriptions that belongs to the given class.

=cut

sub unregister_class {
    my ($class, $c) = @_;
    $c //= blessed($class) ? $class->c : die "The parameter c is needed";
    my $abbrev_class      = $class->abbrev_class;
    my $subscription_hash = delete $class->_channels_stash($c)->{$abbrev_class};
    return [] unless $subscription_hash;
    my $removed_ids = [map { $_->uuid } (values %$subscription_hash)];
    return $removed_ids;
}

=head2 introspect

Introspecting the subscriptions.
It takes the following arguments:

=over 4

=item class

=item c -- Mojolicious::Controller object

=back

It returns the stats information.

=cut

sub introspect {
    my ($class, $c) = @_;
    my $uuid_stash = $class->_uuid_channel_stash($c);
    my (%stats, %channels);
    for my $uuid (keys %$uuid_stash) {
        unless ($uuid_stash->{$uuid}) {
            delete $uuid_stash->{$uuid};
            next;
        }
        my $worker = $uuid_stash->{$uuid};
        next unless $worker->status;    # we only care about the objects that do subscribing.
        my $abbrev_class = $worker->abbrev_class;

        $stats{$abbrev_class}{subscription_count}++;
        $stats{$abbrev_class}{channel_count}++ if not exists $channels{$abbrev_class}{$worker->channel};
        $channels{$abbrev_class}{$worker->channel} = 1;
    }

    return \%stats;
}

1;

