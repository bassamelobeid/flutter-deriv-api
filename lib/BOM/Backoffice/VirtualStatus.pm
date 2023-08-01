package BOM::Backoffice::VirtualStatus;

use strict;
use warnings;

=head1 BOM::Backoffice::VirtualStatus

A testable package to compute virtual statuses. 

Meant to provide missing statuses that would be computed by the RPC on the fly.

Note: nothing to do with virtual accounts, think about artificially injected statuses.

=cut

use BOM::User::Client;
use Date::Utility;

=head2 get

Obtains a hash of virtual statuses.

It takes the following arguments:

=over 4

=item C<$client> - the client being computed.

=cut 

=back

Return a hash of statuses.

=cut

sub get {
    my ($client) = @_;

    my %list = (
        'Withdrawal Locked' => _withdrawal_locked($client),
        'Cashier Locked'    => _cashier_locked($client));

    return map { $list{$_} ? ($_ => $list{$_}) : () } keys %list;
}

=head2 _cashier_locked

Computes the virtual C<cashier_locked> status.

It takes the following arguments:

=over 4

=item C<$client> - the client being computed.

=back 

Returns a virtual C<cashier_locked> status hashref or C<undef> if there is no need to add it.

=cut

sub _cashier_locked {
    my ($client) = @_;

    # skip if the status is there
    return undef if $client->status->cashier_locked;

    my %reasons = (
        'POI has expired' => $client->documents->expired,
    );

    return _build_fake_status('cashier_locked', %reasons);
}

=head2 _withdrawal_locked

Computes the virtual C<withdrawal_locked> status.

It takes the following arguments:

=over 4

=item C<$client> - the client being computed.

=back 

Returns a virtual C<withdrawal_locked> status hashref or C<undef> if there is no need to add it.

=cut

sub _withdrawal_locked {
    my ($client) = @_;

    # skip if the status is there
    return undef if $client->status->withdrawal_locked;

    my %reasons = (
        'FA needs to be completed' => !$client->is_financial_assessment_complete(1),
    );

    return _build_fake_status('withdrawal_locked', %reasons);
}

=head2 _build_fake_status

Build and returns an status look-a-like hashref

=cut

sub _build_fake_status {
    my ($status_code, %reasons) = @_;

    # there must be at least one valid reason to slap the status
    return undef unless grep { $_ } values %reasons;

    return {
        last_modified_date => Date::Utility->new->datetime_yyyymmdd_hhmmss,
        reason             => join('. ', map { $reasons{$_} ? $_ : () } sort keys %reasons),
        staff_name         => 'SYSTEM',
        status_code        => $status_code,
        warning            => 'var(--color-red)',
    };
}

1;
