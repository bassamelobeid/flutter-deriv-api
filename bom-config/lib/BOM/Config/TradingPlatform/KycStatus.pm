use Object::Pad;

class BOM::Config::TradingPlatform::KycStatus;

use strict;
use warnings;
no autovivification;

=head1 NAME

C<BOM::Config::TradingPlatform::KycStatus>

=head1 DESCRIPTION

A class helper functions to return trading platform know your customer status config.

It does not exports these functions by default.

=cut

use Syntax::Keyword::Try;
use List::Util qw(any);

use BOM::Config::Runtime;
use BOM::Config;

=head2 kyc_config

Contain the config of cfds_kyc_status.yml

=cut

field $kyc_config : reader;

=head2 kyc_statuses

Hash reference of kyc status and its config.

=cut

field $kyc_statuses : reader = {};

=head2 new

Builder method to create new instance of this class.

=cut

BUILD {
    $kyc_config = BOM::Config::cfds_kyc_status_config();

    die "Cannot load cfds_kyc_status config." unless $kyc_config;

    foreach my $kyc_status (keys %{$kyc_config->{kyc_status}}) {
        $kyc_statuses->{$kyc_status} = $kyc_config->{kyc_status}->{$kyc_status};
    }
}

=head2 get_kyc_status_list

Return the list of kyc status trading platform account can have

=cut

method get_kyc_status_list {
    return keys %$kyc_statuses;
}

=head2 get_kyc_status_color

Return the color given the kyc status and platform

=over

=item * C<status> kyc status, example: poa_pending

=item * C<platform> trading platform, example: mt5

=back

Color code used by supported platform

=cut

method get_kyc_status_color {
    my $args = shift;
    my ($status, $platform) = @{$args}{qw/status platform/};

    my $kyc_status_color = $kyc_statuses->{$status}->{platform}->{$platform}->{color_code};

    die "Cannot find color for $status and $platform" unless defined $kyc_status_color;

    return $kyc_status_color;
}

=head2 get_kyc_cashier_permission

Return the cashier permission given the kyc status and operation

=over

=item * C<status> kyc status, example: poa_pending

=item * C<operation> cashier operation, example: deposit, withdrawal

=back

Boolean value to indicate whether the cashier operation is allowed for the kyc status

=cut

method get_kyc_cashier_permission {
    my $args = shift;
    my ($status, $operation) = @{$args}{qw/status operation/};

    return 1 unless defined $kyc_statuses->{$status};

    my $kyc_cashier_permission = $kyc_statuses->{$status}->{cashier}->{$operation};

    die "Cannot find cashier permission for $status and $operation" unless defined $kyc_cashier_permission;

    return $kyc_cashier_permission;
}

=head2 get_mt5_account_color_code

Return the color code given color type

=over

=item * C<color_type> Type of color, example: red, none

=back

Color code used by mt5 platform

=cut

method get_mt5_account_color_code {
    my $args = shift;
    my ($color_type) = @{$args}{qw/color_type/};

    my $mt5_color_code = $kyc_config->{mt5_color_code}->{$color_type};

    die "Cannot find color for $color_type" unless defined $mt5_color_code;

    return $mt5_color_code;
}

=head2 is_kyc_cashier_disabled

Return the boolean value to indicate whether the cashier operation is fully disabled for the kyc status

=over

=item * C<status> kyc status, example: poa_pending

=back

Boolean value in integer

=cut

method is_kyc_cashier_disabled {
    my $args = shift;
    my ($status) = @{$args}{qw/status/};

    return 0 unless defined $status;
    return 0 unless defined $kyc_statuses->{$status};

    my $deposit_permission    = $kyc_statuses->{$status}->{cashier}->{deposit};
    my $withdrawal_permission = $kyc_statuses->{$status}->{cashier}->{withdrawal};

    return 1 if not $deposit_permission and not $withdrawal_permission;

    return 0;
}

1;
