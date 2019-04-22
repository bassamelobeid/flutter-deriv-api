package BOM::OAuth::Static;

use strict;
use warnings;

use Exporter qw( import );
our @EXPORT_OK = qw(get_message_mapping);

=head1 NAME

BOM::OAuth::Static

=head1 SYNOPSIS

=head1 DESCRIPTION

This class provides static configurations like error mapping and generic message mapping

=cut

my $config = {
    messages => {
        INVALID_USER         => "Invalid user.",
        INVALID_EMAIL        => "Email not given.",
        INVALID_SOCIAL_EMAIL => "Please grant access to your email address to log in with [_1]",
        INVALID_PASSWORD     => "Password not given.",
        USER_NOT_FOUND       => "Incorrect email or password. Please check if you previously logged in via a social network.",
        NO_SOCIAL_SIGNUP     => "Incorrect email or password. Please check if you previously logged in via a social network.",
        NO_LOGIN_SIGNUP      => "Invalid login attempt. Please log in with your email and password instead.",
        TEMP_DISABLED        => "Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.",
        DISABLED             => "This account has been disabled.",
        NO_USER_IDENTITY     => "Failed to get user identity.",
        ADDITIONAL_SIGNIN =>
            "An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3] and browser: [_4]. If this additional sign-in was not performed by you, please contact our Customer Support team.",
        ADDITIONAL_SIGNIN_THIRD_PARTY =>
            "An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3], browser: [_4] and app: [_5]. If this additional sign-in was not performed by you, please contact our Customer Support team.",
        NEW_SIGNIN_ACTIVITY => "New Sign-In Activity Detected",
        TFA_FAILURE         => "Invalid authentication code",
        NO_AUTHENTICATION   => "Please log in to your social account to continue.",
        INVALID_RESIDENCE   => "Sorry, our service is currently unavailable in [_1].",
        INVALID_PROVIDER    => "The email address you provided is already registered with your [_1] account.",
        'duplicate email' =>
            "Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.",
        'InvalidBrand'        => "Brand is invalid.",
        'invalid'             => "Sorry, an error occurred. Please try again later.",
        'UNAUTHORIZED_ACCESS' => 'Sorry, your account is not authorized to access this application.',
    },
};

=head2 get_message_mapping

Return message mapping for all the error message related to Contract

=cut

sub get_message_mapping {
    return $config->{messages};
}

1;

