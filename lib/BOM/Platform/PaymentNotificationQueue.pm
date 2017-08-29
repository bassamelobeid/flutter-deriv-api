package BOM::Platform::PaymentNotificationQueue;

use strict;
use warnings;

use feature qw(state);

=head1 NAME

BOM::Platform::PaymentNotificationQueue

=head1 DESCRIPTION

Pushes information about deposits and withdrawals to a queue so we can
send information to adwords/analytics/facebook.

=cut

no indirect;

use Try::Tiny;

use Mojo::Redis2;
use Future;
use Future::Mojo;
use JSON::XS qw(encode_json);
use YAML::XS qw(LoadFile);

use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge stats_inc);
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

our $REDIS;

sub redis {
    unless($REDIS) {
        my $redis_cfg = LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};
        my $redis_url = Mojo::URL->new("redis://$redis_cfg->{host}:$redis_cfg->{port}");
        $redis_url->userinfo('user:' . $redis_cfg->{password}) if $redis_cfg->{password};
        $REDIS = Mojo::Redis2->new(url => $redis_url);
    }

    return $REDIS;
}

sub disconnect {
    undef $REDIS;
}

=head2 add

Adds a notification to our queue.

Returns a L<Future> which will resolve as done if the publish was successful.

=cut

sub add {
    my ($class, %args) = @_;
    # We are not interested in deposits from payment agents
    return Future->done(undef) if $args{payment_agent};
    # Skip any virtual accounts
    return Future->done(undef) if $args{loginid} =~ /^VR/;

    $args{amount_usd} = in_USD($args{amount} => $args{currency});
    my $data = encode_json(\%args);

    my $f = $class->publish('payment_notification_queue' => $data);
    # Rescale by 100x to ensure we send integers (all amounts in USD)
    stats_timing('payment.' . $args{type} . '.usd', abs(int(100.0 * $args{amount_usd})), {tag => ['source:' . $args{source}]});
    return $f;
}

sub add_sync {
    my ($class, %args) = @_;
    try {
        my $f = $class->add(%args);
        $f->get;
    }
    catch {
        warn "Redis notification failed: $_\n";
        stats_inc('payment.' . $args{type} . '.notification.error', {tag => ['source:' . $args{source}]});
    };
    return;
}

=head2 publish

Publish a Redis notification using the given key and value.

Takes the following parameters:

=over 4

=item * C<< $k >> - the Redis key we want to publish to

=item * C<< $v >> - the payload to send

=back

Returns a L<Future> which will:

=over 4

=item * if the publish worked successfully, resolves to done with the number of subscribers

=item * if the Redis connection failed for any reason, resolves as failed with the error details

=item * if the hardcoded 3-second timeout expires, resolves as failed with C<< Redis connection timeout exceeded >>.

=back

Usage:

 $class->publish(payment_notification_queue => $json->encode({ type => 'deposit' }));

=cut

sub publish {
    my ($class, $k, $v) = @_;
    my $redis = $class->redis;
    my $loop  = Mojo::IOLoop->new;

    # We have a hardcoded 3-second timeout to avoid the payment API calls taking
    # too long for cashier callbacks.
    my $timeout = Future::Mojo->new($loop);
    $loop->timer(
        3 => sub {
            $timeout->fail('Redis connection timeout exceeded');
        });

    my $f = Future::Mojo->new($loop);
    $redis->publish(
        $k => $v,
        sub {
            my ($self, $count, $err) = @_;
            stats_gauge('payment.notification.listeners', $count);
            if ($err) {
                $f->fail(
                    $err,
                    payment_notification => $k,
                    $v
                );
                return;
            }
            $f->done($count);
            return;
        });

    return Future->wait_any($f, $timeout,);
}

1;
