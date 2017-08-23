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

use Mojo::Redis2;
use Future;
use JSON::XS qw(encode_json);

use DataDog::DogStatsd::Helper qw(stats_timing);
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

# TODO This must be in config, so we should add to chef
my $redis_url = 'redis://localhost:6379';

sub redis {
    state $redis = Mojo::Redis2->new(url => $redis_url);
    return $redis;
}

sub add {
    my ($class, %args) = @_;
    my $redis = $class->redis;
    $args{amount_usd} = in_USD($args{amount} => $args{currency});
    my $data = encode_json(\%args);
    $redis->publish('payment_notification_queue', $data);
    stats_timing('payment.deposit.usd', $args{amount_usd}, {tag => ['source:' . $args{source}]});
    return Future->done;
}

1;
