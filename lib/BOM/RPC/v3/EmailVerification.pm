package BOM::RPC::v3::EmailVerification;

use strict;
use warnings;

use BOM::Platform::Context qw(localize);
use BOM::RPC::v3::Utility;

use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(email_verification);

=head2 email_verification

Description: Creates verification email messages  for the different verification types that are called using the verify_email api call. 
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

Returns a Hash Reference of subroutines  used in the calling code, e.g. C<< email_verification()->{account_opening_new}->() >>

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

    my $password_reset_url = 'https://www.'
        # Redirect Binary.me and Binary Desktop to binary.me
        . ($source == 15284 || $source == 14473 ? 'binary.me' : $website_name) . '/'
        . lc($language)
        . ($website_name =~ /champion/i ? '/lost-password.html' : '/user/lost_passwordws.html');

    return {
        account_opening_new => sub {
            return {
                subject => localize('Verify your email address - [_1]', $website_name),
                message => $verification_uri
                ? localize(
                    '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Click the following link to verify your account:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    _build_verification_url('signup', $args),
                    $website_name
                    )
                : localize(
                    '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Enter the following verification token into the form to create an account: <p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $code,
                    $website_name
                ),
            };
        },
        account_opening_existing => sub {
            return {
                # Check the user is trying to sign up from binary.com
                $source == 1
                ? (
                    subject => localize('Duplicate email address submitted - [_1]', $website_name),
                    message => '<div style="line-height:200%;color:#333333;font-size:15px;">'
                        . localize(
                        '<p>It seems that you tried to sign up with an email address that\'s already in the [_2] system.</p><p>You may have</p><ul><li>Previously signed up with [_2] using the same email address, or</li><li>Signed up with another trading application that uses [_2] technology.</li></ul><p>If you have forgotten your password, please <a href="[_1]">reset your password</a> now to access your account.</p><p>If this wasn\'t you, please ignore this email.</p><p style="color:#333333;font-size:15px;">Regards,<br/>[_2]</p>',
                        $password_reset_url,
                        $website_name,
                        )
                        . '</div>'
                    )
                : (
                    subject => localize('Duplicate email address submitted to [_1] (powered by [_2])', $app_name, $website_name),
                    message => '<div style="line-height:200%;color:#333333;font-size:15px;">'
                        . localize(
                        '<p>[_3] is one of many trading applications powered by [_2] technology. It seems that you tried to sign up with an email address that\'s already in the [_2] system.</p><p>You may have</p><ul><li>Previously signed up with [_3] using the same email address, or</li><li>Signed up with another trading application that uses [_2] technology.</li></ul><p>If you have forgotten your password, please <a href="[_1]">reset your password</a> now to access your account.</p><p>If this wasn\'t you, please ignore this email.</p><p style="color:#333333;font-size:15px;">Regards,<br/>[_2]</p>',
                        $password_reset_url, $website_name, $app_name,)
                        . '</div>'
                ),
            };
        },
        payment_withdraw => sub {
            my $type_call = shift;

            my $payment_withdraw =
                $verification_uri
                ? localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the link below:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                _build_verification_url('payment_withdraw', $args),
                $website_name
                )
                : localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment withdrawal form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                $code, $website_name
                );

            my $payment_withdraw_agent =
                $verification_uri
                ? localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the link below:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                _build_verification_url('payment_agent_withdraw', $args),
                $website_name
                )
                : localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment agent withdrawal form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                $code, $website_name
                );

            return {
                subject => localize('Verify your withdrawal request - [_1]', $website_name),
                message => $type_call eq 'payment_withdraw' ? $payment_withdraw : $payment_withdraw_agent,
            };
        },
        reset_password => sub {
            return {
                subject => localize('Reset your [_1] account password', $website_name),

                message => $verification_uri
                ? (
                    $has_social_signup
                    ? localize(
                        '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. If it was you, we\'d be glad to help.</p><p>Before we proceed, we noticed you are logged in using your (Google/Facebook) account. Please note that if you reset your password, your social account login will be deactivated. If you wish to keep your social account login, you would need to remember your (Google/Facebook) account password.</p><p>If you\'re ready, <a href="[_2]">reset your password now.<a></p><p>Not you? Unsure? <a href="https://www.binary.com/en/contact.html">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                        $user_name || 'there',
                        _build_verification_url('reset_password', $args),
                        $website_name
                        )
                    : localize(
                        '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. If it was you, you may <a href="[_2]">reset your password now.<a></p><p>Not you? Unsure? <a href="https://www.binary.com/en/contact.html">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                        $user_name || 'there',
                        _build_verification_url('reset_password', $args),
                        $website_name
                    ))
                : localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. Please use the token below to create your new password.</p><p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_2]</span></p><p>Not you? Unsure? <a href="https://www.binary.com/en/contact.html">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                    $user_name || 'there',
                    $code,
                    $website_name
                ),
            };
        },
        mt5_password_reset => sub {
            return {
                subject => localize('[_1] New MT5 Password Request', $website_name),
                message => $verification_uri
                ? localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your MT5 password, please help us to verify your identity by clicking the link below:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    _build_verification_url('mt5_password_reset', $args),
                    $website_name
                    )
                : localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your MT5 password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $code,
                    $website_name
                ),
            };
        }
    };
}

=head2 _build_verification_uri

Description: builds the verifiation URl with optional UTM parameters
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
