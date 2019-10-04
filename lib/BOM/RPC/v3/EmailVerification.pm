package BOM::RPC::v3::EmailVerification;

use strict;
use warnings;

use BOM::Platform::Context qw(localize request);
use BOM::RPC::v3::Utility;
use BOM::Config;

use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(email_verification);

=head2 email_verification

Description: Creates arguments needed to process verification email messages for
the different verification types that are called using the verify_email api call.

Takes the following arguments as named parameters

=over 4

=item * C<code> - the one-off link verification code

=item * C<website_name> The name of the website the verification request came from

=item * C<verification_uri> The base string of the url to build the link from

=item * C<language> the language of the client

=item * C<source> the app_id of the requesting application.

=item * C<app_name>  the application name associated with the application id

=back

=head3 optional attributes,

These following named parameters are optional and come from the attributes of the verify_email/url_parameters api call,  these are appended to the
url used in the verification email.

=over 4

=item * C<date_first_contact>  string [Optional] Date of first contact, format: yyyy-mm-dd in GMT timezone.

=item * C<gclid_url> string [Optional] Google Click Identifier to track source.

=item * C<residence> string 2-letter country code (obtained from residence_list call).

=item * C<utm_medium> string [Optional] Identifies the medium the link was used upon such as: email, CPC, or other methods of sharing.

=item * C<utm_source> string [Optional] Identifies the source of traffic such as: search engine, newsletter, or other referral.

=item * C<signup_devicem> mobile | desktop [Optional] Show whether user has used mobile or desktop.

=item * C<affiliate_token> string [Optional] Affiliate token, within 32 characters.

=item * C<verification_code> string Email verification code (received from a verify_email call, which must be done first).

=item * C<utm_campaign> string [Optional] Identifies a specific product promotion or strategic campaign such as a spring sale or other promotions.

=back

Returns a Hash Reference of subroutines used in the calling code,
e.g. C<< email_verification()->{account_opening_new}->() >>

Each subroutine returns a Hash Reference containing arguments needed to send the
email: C<subject>, C<template_name>, C<template_args>

=cut

sub email_verification {
    my $args = shift;

    my $code             = $args->{code};
    my $website_name     = $args->{website_name};
    my $verification_uri = $args->{verification_uri};
    my $language         = $args->{language};
    my $source           = $args->{source};
    my $app_name         = $args->{app_name};

    my ($has_social_signup, $user_name);
    if ($code and my $user = BOM::RPC::v3::Utility::get_user_by_token($code)) {
        $has_social_signup = $user->{has_social_signup};
        $user_name         = ($user->clients)[0]->last_name;
    }

    my $brand              = request()->brand;
    my $password_reset_url = 'https://www.'
        # Redirect Binary.me and Binary Desktop to binary.me
        . ($source == 15284 || $source == 14473 ? $brand->whitelist_apps->{15284} : $website_name) . '/'
        . lc($language)
        . ($website_name =~ /champion/i ? '/lost-password.html' : '/user/lost_passwordws.html');

    my $contact_url = 'https://www.' . lc($brand->website_name) . '/en/contact.html';

    my %common_args = (
        $args->%*,
        contact_url        => $contact_url,
        has_social_signup  => $has_social_signup,
        password_reset_url => $password_reset_url,
        user_name          => $user_name,
    );

    return {
        account_opening_new => sub {
            my $subject =
                $brand->name eq 'deriv'
                ? localize('Verify your account for Deriv')
                : localize('Verify your email address - [_1]', $website_name);

            return {
                subject       => $subject,
                template_name => 'account_opening_new',
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url('signup', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        account_opening_existing => sub {
            my $subject =
                  $brand->name eq 'deriv' ? localize('This email is taken')
                : $source == 1 ? localize('Duplicate email address submitted - [_1]', $website_name)
                :                localize('Duplicate email address submitted to [_1] (powered by [_2])', $app_name, $website_name);

            return {
                subject       => $subject,
                template_name => 'account_opening_existing',
                template_args => {%common_args},
            };
        },
        payment_withdraw => sub {
            my $type_call = shift;

            my $is_paymentagent = $type_call eq 'paymentagent_withdraw' ? 1 : 0;
            $type_call = 'payment_agent_withdraw' if $is_paymentagent;

            return {
                subject       => localize('Verify your withdrawal request - [_1]', $website_name),
                template_name => 'payment_withdraw',
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url($type_call, $args))
                        : ()
                    ),
                    is_paymentagent => $is_paymentagent,
                    %common_args,
                },
            };
        },
        reset_password => sub {
            return {
                subject       => localize('Reset your [_1] account password', $website_name),
                template_name => 'reset_password',
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url('reset_password', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        mt5_password_reset => sub {
            return {
                subject       => localize('[_1] New MT5 Password Request', $website_name),
                template_name => 'mt5_password_reset',
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url('mt5_password_reset', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        }
    };
}

=head2 _build_verification_uri

Description: builds the verification URl with optional UTM parameters
Takes the following arguments as parameters

=over 4

=item * C<$action>  The type of action this verification applies to, sent in by the API call

=item * C<$args>  A hash ref of arguments, that build the rest of the url "language" and "code" are required , utm_source utm_campaign utm_medium signup_device gclid_url date_first_contact affiliate_token are optional.

=back

Returns   string representation of the URL.

=cut

sub _build_verification_url {
    my ($action, $args) = @_;
    my $extra_params_string = '';
    foreach my $extra_param (qw( utm_source utm_campaign utm_medium signup_device gclid_url date_first_contact affiliate_token)) {
        $extra_params_string .= "&$extra_param=" . $args->{$extra_param} if defined($args->{$extra_param});
    }
    return "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}$extra_params_string";
}

1;
