package BOM::Platform::CryptoCashier::Payment::Error;

=head1 NAME

BOM::Platform::CryptoCashier::Payment::Error

=head1 DESCRIPTION

A central place to define crypto cashier payment API error codes and message
as well as functions to create consistent structure for error responses.

=cut

use strict;
use warnings;

use base qw(Exporter);
our @EXPORT_OK = qw(create_error);

our %ERROR_MAP = (
    MissingRequiredParameter => 'The parameter %s is required.',
    ClientNotFound           => 'Cannot identify client for %s.',
    InvalidCurrency          => 'Invalid currency code %s.',
    CurrencyNotMatch         => 'The client currency does not match the payment request currency %s',
    ZeroPaymentAmount        => 'The amount is zero after rounding.',
    FailedCredit             => 'Failed to credit the client account for crypto id: %s',
    FailedDebit              => 'Failed to debit the client account for crypto id: %s',
    InvalidPayment           => 'Invalid payment: %s',
    UnknownError             => 'An unknown error has occurred.',
    SiblingAccountNotFound   => 'Wrong currency deposit. Client doesnt have the correct account. crypto id: %s',
    FailedRevert             => 'Failed to revert the client\'s withdrawal for crypto id: %s',
    MissingWithdrawalPayment => 'Withdrawal paymnet not found for crypto id: %s',
);

=head2 create_error

Creates the standard error structure.

Takes the following parameters:

=over 4

=item * C<$error_code> - A key from C<%ERROR_MAP> hash as string

=item * C<%options> - List of possible options to be used in creating the error, containing the following keys:

=over 4

=item * C<message_params> - List of values for placeholders to pass to C<sprintf>, should be arrayref if more than one value

=back

=back

Returns error as hashref containing the following keys:

=over 4

=item * C<code> - The error code from C<%ERROR_MAP>

=item * C<message> - The error message

=back

=cut

sub create_error {
    my ($error_code, %options) = @_;

    my $message = $ERROR_MAP{$error_code} || $ERROR_MAP{UnknownError};

    if (my $params = $options{message_params}) {
        my @params = ref $params eq 'ARRAY' ? $params->@* : ($params);
        $message = sprintf($message, @params);
    }

    return {
        code    => $error_code,
        message => $message,
    };
}

1;
