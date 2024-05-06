package BOM::RPC::v3::EmailVerification;

use strict;
use warnings;

use BOM::Platform::Context qw(localize request);
use BOM::RPC::v3::Utility;
use BOM::Config;
use BOM::Service;

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

    my ($has_social_signup, $last_name, $first_name);

    my $user_data = BOM::Service::user(
        context    => delete $args->{user_service_context},
        command    => 'get_attributes',
        user_id    => $email,
        attributes => [qw(has_social_signup last_name first_name)],
    );

    if ($user_data->{status} eq 'ok') {
        $has_social_signup = $user_data->{has_social_signup};
        $last_name         = $user_data->{last_name};
        $first_name        = $user_data->{first_name};
    }

    my $brand  = request()->brand;
    my $params = {
        website_name => $website_name,
        source       => $source,
        language     => $language,
        app_name     => $app_name
    };
    my $password_reset_url  = $brand->password_reset_url($params);
    my $contact_url         = $brand->contact_url($params);
    my $password_change_url = $brand->password_change_url($params);
    my $mt5_dashboard_url   = $brand->mt5_dashboard_url($params);

    my %common_args = (
        $args->%*,
        contact_url        => $contact_url,
        has_social_signup  => $has_social_signup,
        password_reset_url => $password_reset_url,
        user_name          => $last_name,
        support_email      => $brand->emails('support'),
        live_chat_url      => $brand->live_chat_url,
        email              => $email,
    );

    return {
        account_opening_new => sub {
            return {
                template_args => {
                    name  => $first_name,
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
            return {
                template_args => {
                    login_url => 'https://oauth.' . lc($brand->website_name) . '/oauth2/authorize?app_id=' . $source . '&brand=' . $brand->name,
                    name      => $first_name,
                    title     => localize('Your email address looks familiar'),
                    %common_args,
                },
            };
        },
        account_verification => sub {
            return {
                template_args => {
                    name  => $first_name,
                    title => localize('Verify your email'),
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('verify_account', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        self_tagging_affiliates => sub {
            return {
                template_args => {
                    name  => $first_name,
                    title => localize("Here's how to create your Deriv account"),
                    %common_args,
                },
            };
        },
        payment_withdraw => sub {
            my $is_paymentagent = $type eq 'paymentagent_withdraw' ? 1                        : 0;
            my $action          = $is_paymentagent                 ? 'payment_agent_withdraw' : $type;

            return {
                template_args => {
                    name  => $first_name,
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
            return {
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url('reset_password', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        request_email => sub {
            return {
                template_args => {(
                        $verification_uri
                        ? (verification_url => _build_verification_url('request_email', $args))
                        : ()
                    ),
                    %common_args,
                },
            };
        },
        closed_account => sub {
            return {
                template_args => {
                    name => $first_name,
                    %common_args,
                },
            };
        },
        trading_platform_password_reset => sub {
            # TODO - Currently too hard to remove the $user here because of the usage of
            # TODO - the clients_for_landing_company method. Is there a way to tell from
            # TODO - user only if the user has access to dxtrade?
            my $user = BOM::User->new(email => $email);

            return {
                subject       => localize('Your new trading password request'),
                template_name => 'reset_password_request',
                template_args => {
                    name          => $first_name,
                    title         => localize("Forgot your trading password?[_1]Let's get you a new one.", '<br>'),
                    title_padding => 50,
                    brand_name    => ucfirst $brand->name,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('trading_platform_password_reset', $args))
                        : ()
                    ),
                    is_trading_password => 1,
                    dxtrade_available   => $user->clients_for_landing_company('svg') ? 1 : 0,    # TODO: add some sort of LC entry for this
                    %common_args,
                },
            };
        },
        trading_platform_mt5_password_reset => sub {
            my $display_name = BOM::RPC::v3::Utility::trading_platform_display_name('mt5');

            return {
                subject       => localize('New [_1] password request', $display_name),
                template_name => 'reset_password_request',
                template_args => {
                    name          => $first_name,
                    title         => localize('Need a new [_1] password?', $display_name),
                    title_padding => 50,
                    brand_name    => ucfirst $brand->name,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('trading_platform_mt5_password_reset', $args))
                        : ()
                    ),
                    is_trading_password => 1,
                    display_name        => $display_name,
                    password_change_url => $password_change_url,
                    %common_args,
                },
            };
        },
        trading_platform_dxtrade_password_reset => sub {
            my $display_name = BOM::RPC::v3::Utility::trading_platform_display_name('dxtrade');

            return {
                subject       => localize('New [_1] password request', $display_name),
                template_name => 'reset_password_request',
                template_args => {
                    name          => $first_name,
                    title         => localize('Need a new [_1] password?', $display_name),
                    title_padding => 50,
                    brand_name    => ucfirst $brand->name,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('trading_platform_dxtrade_password_reset', $args))
                        : ()
                    ),
                    is_trading_password => 1,
                    display_name        => $display_name,
                    password_change_url => $password_change_url,
                    %common_args,
                },
            };
        },
        trading_platform_investor_password_reset => sub {
            my $display_name = BOM::RPC::v3::Utility::trading_platform_display_name('mt5');

            return {
                subject       => localize('New [_1] investor password request', $display_name),
                template_name => 'reset_password_request',
                template_args => {
                    name          => $first_name,
                    title         => localize('Need a new [_1] investor password?', $display_name),
                    title_padding => 50,
                    brand_name    => ucfirst $brand->name,
                    (
                        $verification_uri
                        ? (verification_url => _build_verification_url('trading_platform_investor_password_reset', $args))
                        : ()
                    ),
                    is_investor_password => 1,
                    display_name         => $display_name,
                    mt5_dashboard_url    => $mt5_dashboard_url,
                    %common_args,
                },
            };
        },
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

    my $regex_validation = {qr{^utm_.+} => qr{^[\w\s\.\-_]{1,100}$}};
    my @tags_list        = qw(
        utm_source       utm_campaign utm_medium  signup_device   gclid_url      date_first_contact
        affiliate_token  utm_content  utm_term    utm_campaign_id utm_adgroup_id utm_ad_id
        utm_gl_client_id utm_msclk_id utm_fbcl_id utm_adrollclk_id
        redirect_to      bta
    );
    my $extra_params_filtered = BOM::Platform::Utility::extract_valid_params(\@tags_list, $args, $regex_validation);

    my @extra_params = keys $extra_params_filtered->%*;
    push @extra_params, qw ( pa_loginid pa_amount pa_currency pa_remarks ) if ($action eq 'payment_agent_withdraw');

    @extra_params = map { defined $args->{$_} ? join('=', $_, $args->{$_}) : () } sort @extra_params;
    my $extra_params_string = @extra_params ? '&' . join('&', @extra_params) : '';

    if ($action eq 'payment_withdraw' || $action eq 'payment_agent_withdraw') {
        return "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}&loginid=$args->{loginid}$extra_params_string";
    }
    return "$args->{verification_uri}?action=$action&lang=$args->{language}&code=$args->{code}$extra_params_string";
}

1;
