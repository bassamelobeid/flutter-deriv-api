package BOM::Backoffice::UserService;

use warnings;
use strict;

=head1 NAME

BOM::Backoffice::UserService - A helper module for user-service operations in the backoffice.

=head1 SYNOPSIS

    use BOM::Backoffice::UserService;

    my $context = BOM::Backoffice::UserService::get_context();

=head1 DESCRIPTION

This module provides a service for handling user-related operations in the backoffice.

=head2 METHODS

=head3 get_context

    my $context = BOM::Backoffice::UserService::get_context();

This method returns a hash reference containing the correlation_id and auth_token. The correlation_id is a string that combines 'backoffice:' with the AUDIT_STAFF_NAME and AUDIT_STAFF_IP environment variables. The auth_token is a static string 'Unused but required to be present'.

=cut

sub get_context {
    return {
        correlation_id => 'backoffice:' . ($ENV{AUDIT_STAFF_NAME} // '' . ':' . $ENV{AUDIT_STAFF_IP}),
        auth_token     => 'Unused but required to be present',
    };
}

1;
