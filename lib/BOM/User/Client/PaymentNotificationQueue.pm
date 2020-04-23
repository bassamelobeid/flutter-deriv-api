package BOM::User::Client::PaymentNotificationQueue;

use strict;
use warnings;

=head1 NAME

BOM::User::Client::PaymentNotificationQueue

=head1 DESCRIPTION

Pushes information about deposits and withdrawals to a queue so we can
send information to adwords/analytics/facebook.

=cut

no indirect;

use Syntax::Keyword::Try;

use Encode;
use JSON::MaybeXS;
use YAML::XS qw(LoadFile);
use IO::Socket::IP;
use BOM::User::Client;
use BOM::User;

use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge stats_inc);
use ExchangeRates::CurrencyConverter qw(in_usd);

my $sock;

sub reload {
    my $cfg = LoadFile($ENV{BOM_PAYMENT_NOTIFICATION_CONFIG} // '/etc/rmg/payment_notification.yml');
    $sock = IO::Socket::IP->new(
        Proto    => "udp",
        PeerAddr => $cfg->{host},
        PeerPort => $cfg->{port},
    ) or die "can't connect to notification service";
    $sock->blocking(0);
    return;
}

sub import {
    reload() unless $sock;
    return;
}

=head2 add

Adds a notification to our queue.

=cut

sub add {
    my ($class, %args) = @_;
    # We are not interested in deposits from payment agents
    return if $args{payment_agent};
    # Skip any virtual accounts
    return if $args{loginid} =~ /^VR/ and ($args{type} eq 'deposit' or $args{type} eq 'withdrawal');

    my $tags = {tags => ['source:' . $args{source}, 'currency:' . $args{currency}]};
    try {
        my $client = BOM::User::Client->new({
                loginid      => $args{loginid},
                db_operation => 'replica'
            }) or die 'client not found';
        my $user = $client->user or die 'user not found';
        $args{$_} = $user->{$_} for qw(utm_source utm_medium utm_campaign);
    }
    catch {
        stats_inc('payment.' . $args{type} . '.user_lookup.failure', $tags);
    }

    # No need to convert the currency if we're in USD already
    $args{amount_usd} //= $args{amount} if $args{currency} eq 'USD';

    # If we don't have rates, that's not worth causing anything else to fail: just tell datadog and bail out.
    try {
        $args{amount_usd} //= $args{amount} ? in_usd($args{amount} => $args{currency}) : 0.0;
    }
    catch {
        stats_inc('payment.' . $args{type} . '.usd_conversion.failure', $tags);
        return;
    };

    try {
        $class->publish(\%args);
    }
    catch {
        warn "Failed to publish - $@";
    }

    # Rescale by 100x to ensure we send integers (all amounts in USD)
    stats_timing('payment.' . $args{type} . '.usd', abs(int(100.0 * $args{amount_usd})), $tags);
    return;
}

=head2 publish

Publish a notification using the given data.

Usage:

 $class->publish({ source => 'doughflow', amount => 123.45 });

=cut

my $json = JSON::MaybeXS->new;

sub publish {
    my ($class, $data) = @_;
    my $bytes = Encode::encode_utf8($json->encode($data));
    $sock->send($bytes);
    return;
}

1;
