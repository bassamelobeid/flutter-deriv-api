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
use BOM::User::PhoneNumberVerification;
use UUID::Tiny;

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
        'MT5 Withdrawal Locked' => _mt5_withdrawal_locked($client),
        'Withdrawal Locked'     => _withdrawal_locked($client),
        'Cashier Locked'        => _cashier_locked($client),
        'Phone Number Verified' => _phone_number_verified($client),
    );

    return map { $list{$_} ? ($_ => $list{$_}) : () } keys %list;
}

=head2 _phone_number_verified

Computes the virtual C<phone_number_verified> status.

It takes the following arguments:

=over 4

=item C<$client> - the client being computed.

=back 

Returns a virtual C<phone_number_verified> status hashref or C<undef> if there is no need to add it.

=cut

sub _phone_number_verified {
    my ($client) = @_;

    my $pnv = BOM::User::PhoneNumberVerification->new(
        $client->binary_user_id,
        +{
            correlation_id => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
            auth_token     => "Unused but required to be present",
            environment    => "bom-backoffice",
        });

    return undef unless $pnv->verified;

    return _build_fake_status(
        'phone_number_verified',
        'OTP challenge pass' => 1,
    );
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

=head2 _mt5_withdrawal_locked

Computes the virtual C<mt5_withdrawal_locked> status.

It takes the following arguments:

=over 4

=item C<$client> - the client being computed.

=back 

Returns a virtual C<mt5_withdrawal_locked> status hashref or C<undef> if there is no need to add it.

=cut

sub _mt5_withdrawal_locked {
    my ($client) = @_;

    # skip if the status is there
    return undef if $client->status->mt5_withdrawal_locked;

    my $has_regulated_mt5 = $client->user->has_mt5_regulated_account(use_mt5_conf => 1);

    my %reasons = (
        'POI has expired' => $has_regulated_mt5 && $client->documents->expired($has_regulated_mt5),
        'POA is outdated' => $has_regulated_mt5 && $client->documents->outdated(),
    );

    return _build_fake_status('mt5_withdrawal_locked', %reasons);
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
