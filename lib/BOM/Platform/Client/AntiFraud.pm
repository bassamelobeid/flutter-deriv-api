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
use BOM::Database::DataMapper::Payment::DoughFlow;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::User::PaymentRecord;
use BOM::Config::Payments::PaymentMethods;

=head2 client

A L<BOM::User::Client> instance.

=cut

has client => (
    is       => 'ro',
    required => 1
);

=head2 df_cumulative_total_by_payment_type

Returns a boolean value that determines whether the
client has passed the current cumulative total per doughflow payment type.

Takes the following params:

=over 4

=item * C<payment_type> - the df payment type we're checking

=back

Returns a bool scalar.

=cut

sub df_cumulative_total_by_payment_type {
    my ($self, $payment_type) = @_;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update();

    my $poi_deposit_limits = decode_json_utf8($app_config->payments->countries->poi_deposit_limits_per_payment_type);
    my $residence          = $self->client->residence;

    if (my $params = $poi_deposit_limits->{$residence}->{$payment_type}) {
        my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({client_loginid => $self->client->loginid});
        my ($limit, $days) = @{$params}{qw/limit days/};
        my $total = $doughflow_datamapper->payment_type_cumulative_total({
            payment_type => $payment_type,
            days         => $days
        });
        my $currency = $self->client->account->currency_code;
        # USD is the base currency for the following computation
        # the converstion rate function can die
        my $usd_total = $currency ne 'USD' ? in_usd($total, $currency) : $total;

        if ($usd_total >= $limit) {
            return 1;
        }
    }

    return 0;
}

=head2 df_total_payments_by_payment_type

Returns a boolean value that determines whether the
client has passed the current limits per payment type (if any).

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

    my $grouped = $record->group_by_id($filtered);

    my $total_payment_accounts = scalar $grouped->@*;
    my $payment_accounts_limit = $self->client->payment_accounts_limit($limit);

    return $total_payment_accounts >= $payment_accounts_limit;
}

1;
