package BOM::Platform::PaymentNotificationQueue;

use strict;
use warnings;

=head1 NAME

BOM::Platform::PaymentNotificationQueue

=head1 DESCRIPTION

Pushes information about deposits and withdrawals to a queue so we can
send information to adwords/analytics/facebook.

=cut

no indirect;

use Try::Tiny;

use JSON::XS qw(encode_json);
use YAML::XS qw(LoadFile);
use IO::Socket::IP;

use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge stats_inc);
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

my $cfg = LoadFile('/etc/rmg/payment_notification.yml');
my $sock = IO::Socket::IP->new(
    Proto    => "udp",
    PeerAddr => $cfg->{host},
    PeerPort => $cfg->{port},
) or die "can't connect to notification service";
$sock->blocking(0);

=head2 add

Adds a notification to our queue.

=cut

sub add {
    my ($class, %args) = @_;
    # We are not interested in deposits from payment agents
    return if $args{payment_agent};
    # Skip any virtual accounts
    return if $args{loginid} =~ /^VR/;

    $args{amount_usd} = in_USD($args{amount} => $args{currency});

    try {
        $class->send(\%args);
    } catch {
        warn "Failed to send - $_";
    }
    # Rescale by 100x to ensure we send integers (all amounts in USD)
    stats_timing('payment.' . $args{type} . '.usd', abs(int(100.0 * $args{amount_usd})), {tag => ['source:' . $args{source}]});
    return;
}

=head2 send

Publish a notification using the given data.

Usage:

 $class->send({ source => 'doughflow', amount => 123.45 });

=cut

sub publish {
    my ($class, $data) = @_;
    my $bytes = encode_json($data);
    $sock->send($bytes);
}

1;
