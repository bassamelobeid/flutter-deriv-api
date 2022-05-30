package BOM::Platform::Client::AntiFraud;

use Moo;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Platform::Client::AntiFraud

=head1 DESCRIPTION

Common place for checks related to anti fraud.

Let all the methods within this class to return a boolean, 
so it represents a certain rule to be broken or not,
we'd like to keep the checkup internals somewhat transparent.

=cut

use BOM::Config::Runtime;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::User::PaymentRecord;
use BOM::Config::Payments::PaymentMethods;

=head2 client

A L<BOM::User::Client> instance.

=cut

has client => (
    is       => 'ro',
    required => 1
);

=head2 df_total_payments_by_payment_type

Returns a boolean value that determines whether the
client has passed the current limits per payment type (if any).

Takes the following params:

=over 4

=item * C<$pt> - the df payment type to filter by

=back

Returns a bool scalar.

=cut

sub df_total_payments_by_payment_type {
    my ($self, $pt) = @_;

    return 0 unless $pt;

    my $pm_config          = BOM::Config::Payments::PaymentMethods->new();
    my $high_risk_settings = $pm_config->high_risk($pt);

    return 0 unless $high_risk_settings;

    my ($limit, $days) = @{$high_risk_settings}{qw/limit days/};

    return 0 unless $limit > 0;

    my $record   = BOM::User::PaymentRecord->new(user_id => $self->client->binary_user_id);
    my $payments = $record->get_raw_payments($days);

    my $filtered = $record->filter_payments({pt => $pt}, $payments);

    my $total_payment_accounts = scalar $filtered->@*;
    my $payment_accounts_limit = $self->client->payment_accounts_limit($limit);

    # TODO: we must take this down when the deprecated redis keys expire
    $total_payment_accounts += $record->get_distinct_payment_accounts_for_time_period(
        payment_type => $pt,
        period       => $days,
    );

    return $total_payment_accounts >= $payment_accounts_limit;
}

1;
