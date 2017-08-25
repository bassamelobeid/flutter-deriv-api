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
use YAML::XS qw(LoadFile);

use DataDog::DogStatsd::Helper qw(stats_timing);
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

my $redis_cfg = LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};
my $redis_url = Mojo::URL->new("redis://$redis_cfg->{host}:$redis_cfg->{port}");
$redis_url->userinfo('user:' . $redis_cfg->{password}) if $redis_cfg->{password};

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
    # Rescale by 100x to ensure we send integers (all amounts in USD)
    stats_timing('payment.' . $args{type} . '.usd', abs(int(100.0 * $args{amount_usd})), {tag => ['source:' . $args{source}]});
    return Future->done;
}

1;
