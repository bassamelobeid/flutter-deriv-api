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
        NO_LOGIN_SIGNUP      => "Invalid login attempt. Please log in with your email and password instead.",
        TEMP_DISABLED        => "Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.",
        DISABLED             => "This account has been disabled.",
        NO_USER_IDENTITY     => "Failed to get user identity.",
        NEW_SIGNIN_SUBJECT   => "Security alert: New sign-in activity",
        DEVICE_ANDROID       => "android",
        DEVICE_IPHONE        => "iphone",
        BROWSER_CHROME       => "Chrome",
        BROWSER_FIREFOX      => "Firefox",
        BROWSER_SAFARI       => "Safari",
        BROWSER_EDGE         => "Edge",
        BROWSER_UC           => "UC",
        TFA_FAILURE          => "Invalid authentication code",
        NO_AUTHENTICATION    => "Please log in to your social account to continue.",
        INVALID_RESIDENCE    => "Sorry, our service is currently unavailable in [_1].",
        INVALID_PROVIDER     => "The email address you provided is already registered with your [_1] account.",
        'duplicate email' =>
            "Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.",
        'InvalidBrand'        => "Brand is invalid.",
        'invalid'             => "Sorry, an error occurred. Please try again later.",
        'UNAUTHORIZED_ACCESS' => 'Sorry, your account is not authorized to access this application. Currently, only USD accounts are allowed.',

        # brand-specific messages
        USER_NOT_FOUND_BINARY => "Incorrect email or password. Please check if you previously logged in via a social network.",
        USER_NOT_FOUND_DERIV  => "Your email and/or password do not match.",

        NO_SOCIAL_SIGNUP_BINARY => "Incorrect email or password. Please check if you previously logged in via a social network.",
        NO_SOCIAL_SIGNUP_DERIV  => "Your email and/or password do not match.",
    },
};

=head2 get_message_mapping

Return message mapping for all the error message related to Contract

=cut

sub get_message_mapping {
    return $config->{messages};
}

1;
