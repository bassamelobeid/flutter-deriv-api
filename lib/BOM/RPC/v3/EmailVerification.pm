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

=item * C<pa_loginid> string [Optional] The payment agent loginid received from the `paymentagent_list` call. Only allowed for payment agent withdraw.

=item * C<pa_amount> number [Optional] The amount to withdraw to the payment agent. Only allowed for payment agent withdraw.

=item * C<pa_currency> string [Optional] The currency code. Only allowed for payment agent withdraw.

=item * C<pa_remarks> string [Optional] Remarks about the withdraw. Only letters, numbers, space, period, comma, - ' are allowed. Only allowed for payment agent withdraw.

=back

Returns a Hash Reference of subroutines used in the calling code,
e.g. C<< email_verification()->{account_opening_new}->() >>

Each subroutine returns a Hash Reference containing arguments needed to send the
email: C<subject>, C<template_name>, C<template_args>

=cut

sub email_verification {
    my $args = shift;

    my ($code, $website_name, $verification_uri, $language, $source, $app_name, $type, $email) =
        @{$args}{qw/code website_name verification_uri language source app_name type email/};

    my ($has_social_signup, $user_name, $name);
    if (my $user = BOM::User->new(email => $email)) {
        $has_social_signup = $user->{has_social_signup};
        $user_name         = ($user->clients)[0]->last_name  if $user->clients;
        $name              = ($user->clients)[0]->first_name if $user->clients;
    }

    my $brand  = request()->brand;
    my $params = {
        website_name => $website_name,
        source       => $source,
        language     => $language,
        app_name     => $app_name
    };
    my $password_reset_url = $brand->password_reset_url($params);
    my $contact_url        = $brand->contact_url($params);

    my %common_args = (
        $args->%*,
        contact_url        => $contact_url,
        has_social_signup  => $has_social_signup,
        password_reset_url => $password_reset_url,
        user_name          => $user_name,
        support_email      => $brand->emails('support'),
    );

    return {
        account_opening_new => sub {
            my $subject =
                $brand->name eq 'deriv'
                ? localize("One more step to create your account")
                : localize('Verify your email address - [_1]', $website_name);

            return {
                subject       => $subject,
                template_name => 'account_opening_new',
                template_args => {
                    name  => $name,
                    title => localize("You're nearly there!"),
                    (
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
                  $brand->name eq 'deriv' ? localize('Your email address is already in use')
                : $source == 1            ? localize('Duplicate email address submitted - [_1]', $website_name)
                :                           localize('Duplicate email address submitted to [_1] (powered by [_2])', $app_name, $website_name);

            return {
                subject       => $subject,
                template_name => 'account_opening_existing',
                template_args => {
                    login_url => 'https://oauth.' . lc($brand->website_name) . '/oauth2/authorize?app_id=' . $source . '&brand=' . $brand->name,
                    name      => $name,
                    title     => localize('Your email address looks familiar'),
                    %common_args,
                },
            };
        },
        payment_withdraw => sub {
            my $is_paymentagent = $type eq 'paymentagent_withdraw' ? 1                        : 0;
            my $action          = $is_paymentagent                 ? 'payment_agent_withdraw' : $type;

            return {
                subject       => localize('Verify your withdrawal request'),
                template_name => 'payment_withdraw',
                template_args => {
                    name  => $name,
                    title => localize('Do you wish to withdraw funds?'),
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url($action, $args))
                        : ()
                    ),
                    is_paymentagent => $is_paymentagent,
                    %common_args,
                },
            };
        },
        reset_password => sub {
            my $subject       = localize('Get a new [_1] account password', ucfirst $brand->name);
            my $template_name = 'reset_password_request';
            my $title         = localize("Forgot your password? Let's get you a new one.");
            my $title_padding = 100;
            if ($has_social_signup && $brand->name ne 'binary') {
                $subject       = localize("Forgot your social password?");
                $template_name = 'lost_password_has_social_login';
                $title         = localize("Forgot your social password?");
                $title_padding = undef;
            }
            return {
                subject       => $subject,
                template_name => $template_name,
                template_args => {
                    name          => $name,
                    title         => $title,
                    title_padding => $title_padding,
                    brand_name    => ucfirst $brand->name,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('reset_password', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        mt5_password_reset => sub {
            my $subject =
                $brand->name eq 'deriv'
                ? localize("Your DMT5 account new password request")
                : localize('[_1] New MT5 Password Request', ucfirst $brand->name);

            return {
                subject       => $subject,
                template_name => 'mt5_password_reset',
                template_args => {
                    name          => $name,
                    title         => localize("Forgot your password? Let's get you a new one."),
                    title_padding => 100,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('mt5_password_reset', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        closed_account => sub {
            my ($subject, $title, $title_padding);
            if ($type eq 'account_opening') {
                $subject = $title = localize("We're unable to sign you up");
            } elsif ($type eq 'reset_password') {
                $subject = $title = localize("We couldn't reset your password");
            } else {
                $subject       = $title = localize("We couldn't verify your email address");
                $title_padding = 90;
            }

            return {
                subject       => $subject,
                template_name => 'verify_email_closed_account',
                template_args => {
                    name          => $name,
                    title         => $title,
                    title_padding => $title_padding,
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
    my @extra_params =
        qw( utm_source utm_campaign utm_medium signup_device gclid_url date_first_contact affiliate_token utm_content utm_term utm_campaign_id utm_adgroup_id utm_ad_id utm_gl_client_id  utm_msclk_id utm_fbcl_id utm_adrollclk_id );

    push @extra_params, qw ( pa_loginid pa_amount pa_currency pa_remarks ) if ($action eq 'payment_agent_withdraw');
    @extra_params = map { defined $args->{$_} ? join('=', $_, $args->{$_}) : () } @extra_params;
    my $extra_params_string = @extra_params ? '&' . join('&', @extra_params) : '';

    return "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}$extra_params_string";
}

1;
