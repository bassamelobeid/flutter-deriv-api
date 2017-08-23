package BOM::Platform::PaymentNotificationQueue;

use strict;
use warnings;

=head1 NAME

BOM::Platform::PaymentNotificationQueue

=head1 DESCRIPTION

Pushes information about deposits and withdrawals to a queue so we can
send information to adwords/analytics/facebook.

=cut

use Mojo::Redis2;
use Future;
use JSON::XS qw(encode_json);

use constant MAX_QUEUE_LENGTH => 1000;

# TODO This must be in config, so we should add to chef
my $redis_url = 'redis://localhost:6359';

sub redis {
    state $redis = Mojo::Redis2->new(url => $redis_url);
    return $redis;
}

sub add {
    my ($class, %args) = @_;
    my $redis = $class->redis;
    my $data = encode_json(\%args);
    $redis->publish('payment_notification_queue', $data);
    return Future->done;
}

1;
