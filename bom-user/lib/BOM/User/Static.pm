package BOM::User::Static;

use strict;
use warnings;

=head1 NAME

BOM::User::Static

=head1 DESCRIPTION

This class provides static configurations like error mapping and generic message mapping;

=cut

use constant CONFIG => {
    errors => {
        # kept camel case because RPC follow this convention
        # it will be consistent in case in future we want to send
        # these as error codes to RPC
        LoginTooManyAttempts                => 'Sorry, you have already had too many unsuccessful attempts. Please try again in 5 minutes.',
        INVALID_CREDENTIALS                 => 'Your email and/or password is incorrect. Perhaps you signed up with a social account?',
        AccountUnavailable                  => 'Your account is deactivated. Please contact us via live chat.',
        AccountSelfClosed                   => 'Your account is deactivated. Please contact us via live chat.',
        LoginDisabledDuoToSystemMaintenance =>
            'Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.',
    },
};

=head2 get_error_mapping

Return error mapping for all the error message related to Contract

=cut

sub get_error_mapping {
    return CONFIG->{errors};
}

1;

