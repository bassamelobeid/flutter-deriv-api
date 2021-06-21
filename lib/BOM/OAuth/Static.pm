package BOM::OAuth::Static;

use strict;
use warnings;

use Exporter qw( import );
our @EXPORT_OK = qw(
    get_message_mapping  get_api_errors_mapping  get_valid_device_types
    get_valid_login_types
);

=head1 NAME

BOM::OAuth::Static

=head1 DESCRIPTION

This class provides static configurations like error mapping and generic message mapping

=cut

my $config = {
    messages => {
        INVALID_USER         => "Invalid user.",
        INVALID_EMAIL        => "Email not given.",
        INVALID_SOCIAL_EMAIL => "Please grant access to your email address to log in with [_1]",
        INVALID_PASSWORD     => "Password not given.",
        NO_LOGIN_SIGNUP      => "Social login is not enabled for this account. Please log in with your email and password instead.",
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
        'duplicate email'    =>
            "Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.",
        InvalidBrand        => "Brand is invalid.",
        invalid             => "Sorry, an error occurred. Please try again later.",
        SUSPICIOUS_BLOCKED  => 'Suspicious activity detected from this device - for safety, login has been blocked temporarily.',
        INVALID_CREDENTIALS => "Your email and/or password is incorrect. Perhaps you signed up with a social account?",
        AccountUnavailable  => 'Your account is deactivated. Please contact us via live chat.',
    },
    api_errors => {
        INVALID_USER               => "Invalid user.",
        INVALID_EMAIL              => "The provided email is invalid.",
        INVALID_PASSWORD           => "The provided password is invalid.",
        INVALID_TOKEN              => "The provided token is invalid.",
        INVALID_APP_ID             => "The provided app_id is invalid.",
        INVALID_EXPIRE_TIMESTAMP   => "The provided expire timestamp is invalid",
        INVALID_BRAND              => "The brand is unknown.",
        INVALID_LOGIN_TYPE         => "The provided login type is invalid.",
        INVALID_DATE_FIRST_CONTACT => "The provided date_first_contact is invalid.",
        NEED_JSON_BODY             => "The request must contains JSON body.",
        UNOFFICIAL_APP             => "Using this endpoint is allowed only for official apps.",
        SUSPICIOUS_BLOCKED         => 'Suspicious activity detected from this device - for safety, login has been blocked temporarily.',
        MISSED_CONNECTION_TOKEN    => "The connection_token not given.",
        SELF_CLOSED                => "The account has been flagged as self-closed.",
        NO_USER_IDENTITY           => "Failed to get user identity.",
        UNKNOWN                    => "An error occurred while processing your request, please try again.",
        INVALID_CREDENTIALS        => "Your email and/or password is incorrect. Perhaps you signed up with a social account?",
        TEMP_DISABLED        => "Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.",
        DISABLED             => "This account has been disabled.",
        NO_AUTHENTICATION    => "Please log in to your social account to continue.",
        INVALID_SOCIAL_EMAIL => "Please grant access to your email address to log in with.",
        INVALID_PROVIDER     => "The email address you provided is already registered with one of your accounts.",
        NO_LOGIN_SIGNUP      => "Social login is not enabled for this account. Please log in with your email and password instead.",
        INVALID_RESIDENCE    => "Sorry, our service is currently unavailable in your region.",
        DUPLICATE_EMAIL      =>
            "Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.",
        NO_APP_TOKEN_FOUND        => "There is no token defined for this application.",
        MISSING_ONE_TIME_PASSWORD => "Please provide an authentication code.",
        TFA_FAILURE               => "Invalid authentication code.",
    }};

=head2 get_message_mapping

Return message mapping for all the error message related to Contract

=cut

sub get_message_mapping {
    return $config->{messages};
}

=head2 get_api_errors_mapping

Return messages mapping for Api errors

=cut

sub get_api_errors_mapping {
    return $config->{api_errors};
}

=head2 get_valid_device_types

Return an array of valid device types

=cut

sub get_valid_device_types {
    return qw(mobile desktop);
}

=head2 get_valid_login_types

Return an array of valid login types

=cut

sub get_valid_login_types {
    return qw( system social );
}

1;
