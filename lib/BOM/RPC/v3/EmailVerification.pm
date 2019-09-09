package BOM::RPC::v3::EmailVerification;

use strict;
use warnings;

use BOM::Platform::Context qw(localize request);
use BOM::RPC::v3::Utility;
use BOM::Config;

use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(email_verification);

# Hacky deriv way - to be refactored in a future card
# note: square brackets must be escaped with ~
my %deriv_content = (
    account_opening_new => q( 
        <tr>
            <td bgcolor="#f3f3f3" align="center" style="padding: 0px 10px 0px 10px;">
                <!--~[if (gte mso 9)|(IE)~]>
                <table align="center" border="0" cellspacing="0" cellpadding="0" width="600"><tr><td align="center" valign="top" width="600">
                <!~[endif~]-->
                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
                    <tr>
                        <td bgcolor="#ffffff" align="left" valign="top" style="padding: 40px 30px 20px 30px; border-top: 2px solid #ff444f;">
                            <h2 style="font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 32px; line-height: 40px; color: #333333; margin: 0;">Verify your account</h2>
                            <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #333333; font-size: 16px; font-weight: 400; line-height: 24px; margin: 16px 0px 0px 0px;">Thanks for signing up. To start trading,<br />please verify your email address by clicking the button below.</p>
                        </td>
                    </tr>
                    <!-- button -->
                    <tr>
                        <td bgcolor="#ffffff" align="left" style="padding: 12px 30px 20px 30px; color: #333333; font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 18px; font-weight: 400; line-height: 25px;">
                            <!--~[if (gte mso 9)|(IE)~]>
                                <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="https://www.deriv.com" style="height:50px;v-text-anchor:middle;width:200px;" arcsize="8%" stroke="f" fillcolor="#ff444f">
                                <w:anchorlock/>
                                <center style="color:#ffffff;font-family:sans-serif;font-size:16px;font-weight:bold;">Verify and start trading</center>
                                </v:roundrect>
                            <!~[endif~]-->
                            <a class="button" href="[_1]" style="mso-hide:all;"><span>Verify and start trading</span></a>
                        </td>
                    </tr>
                    <tr>
                        <td bgcolor="#ffffff" align="left" valign="top" style="padding: 0px 30px 40px 30px;">
                            <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #333333; font-size: 16px; font-weight: 400; line-height: 24px; margin: 16px 0px 0px 0px;">Having trouble with the button?<br />Copy and paste this link into your browser to verify.<br /><a href="[_1]">[_1]</a></p>
                        </td>
                    </tr>
                </table>
                <!--~[if (gte mso 9)|(IE)~]></td></tr></table>
                <!~[endif~]-->
            </td>
        </tr>
    ),
    account_opening_existing => q(
        <tr>
            <td bgcolor="#f3f3f3" align="center" style="padding: 0px 10px 0px 10px;">
                <!--~[if (gte mso 9)|(IE)~]>
                <table align="center" border="0" cellspacing="0" cellpadding="0" width="600"><tr><td align="center" valign="top" width="600">
                <!~[endif~]-->
                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
                    <tr>
                        <td bgcolor="#ffffff" align="center" valign="top" style="padding: 40px 30px 40px 30px; border-top: 2px solid #ff444f;">
                                <a href="https://www.deriv.com">
                                    <img src="https://binary-com.github.io/deriv-email-templates/html/images/open-email.png" width="268" height="180" border="0" style="display: block; max-width: 100%;" alt="Deriv.com">
                                </a>
                        </td>
                    </tr>
                </table>
                <!--~[if (gte mso 9)|(IE)~]></td></tr></table>
                <!~[endif~]-->
            </td>
        </tr>
        <!-- COPY BLOCK -->
        <tr>
            <td bgcolor="#f3f3f3" align="center" style="padding: 0px 10px 0px 10px;">
                <!--~[if (gte mso 9)|(IE)~]>
                <table align="center" border="0" cellspacing="0" cellpadding="0" width="600"><tr><td align="center" valign="top" width="600">
                <!~[endif~]-->
                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
                    <!-- COPY -->
                    <tr>
                        <td bgcolor="#ffffff" align="left" style="padding: 0px 30px 8px 30px;">
                            <h2 style="font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 32px; line-height: 40px; color: #333333; margin: 0;">This email is already in use</h2>
                        </td>
                    </tr>
                    <!-- COPY -->
                    <tr>
                        <td bgcolor="#ffffff" align="left" style="padding: 8px 30px 40px 30px; color: #333333; font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 16px; font-weight: 400; line-height: 24px;">
                            <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #333333; font-size: 16px; font-weight: 400; line-height: 24px; margin: 0px 0px 0px 0px;">The email address you provided <strong>(<a href="[_1]" style="color: #333333 !important;">[_1]</a>)</strong> is already taken. Only one Deriv account can be created with one email address.</p>
                            <p style="margin: 16px 0px 0px 0px;"><a href="https://www.deriv.com">Log in</a></p>
                        </td>
                     </tr>
                </table>
                <!--~[if (gte mso 9)|(IE)~]>
                    </td></tr></table>
                <!~[endif~]-->
            </td>
        </tr>
    ),
    payment_withdraw => q(
        <tr>
            <td bgcolor="#f3f3f3" align="center" style="padding: 0px 10px 0px 10px;">
                <!--~[if (gte mso 9)|(IE)~]>
                <table align="center" border="0" cellspacing="0" cellpadding="0" width="600"><tr><td align="center" valign="top" width="600">
                <!~[endif~]-->
                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
                    <tr>
                        <td bgcolor="#ffffff" align="center" valign="top" style="padding: 50px 30px 40px 30px; border-top: 2px solid #ff444f;">
                            <a href="https://www.deriv.com">
                                <img src="https://binary-com.github.io/deriv-email-templates/html/images/icon-verify-withdrawal.png" width="180" height="180" border="0" style="display: block; max-width: 100%;" alt="Deriv.com">
                            </a>
                        </td>
                    </tr>
                    <tr>
                        <td bgcolor="#ffffff" align="center" valign="top" style="padding: 0px 30px 20px 30px;">
                            <h2 style="font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 32px; line-height: 40px; color: #333333; margin: 0;">Please verify your</h2>
                            <h2 style="font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 32px; line-height: 40px; color: #333333; margin: 0;">withdrawal request</h2>
                        </td>
                    </tr>
                    <tr>
                        <td bgcolor="#ffffff" align="left" valign="top" style="padding: 12px 30px 20px 30px;">
                            <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #333333; font-size: 16px; font-weight: 400; line-height: 24px; margin: 0px 0px 0px 0px;">Before we can proceed with the withdrawal process, we first need to check that it was you who made the request.</p>
                        </td>
                    </tr>
                    <!-- button -->
                    <tr>
                        <td bgcolor="#ffffff" align="center" style="padding: 12px 30px 32px 30px; color: #333333; font-family: 'IBM Plex Sans', Arial, sans-serif; font-size: 18px; font-weight: 400; line-height: 25px;">
                            <!--~[if (gte mso 9)|(IE)~]>
                                <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="[_1]" style="height:50px;v-text-anchor:middle;width:180px;" arcsize="10%" strokecolor="#ff444f" fillcolor="#ffffff">
                                <w:anchorlock/>
                                <center style="color:#ff444f;font-family:sans-serif;font-size:16px;font-weight:bold;">Yes, it's me!</center>
                                </v:roundrect>
                            <!~[endif~]-->
                            <a class="button" href="[_1]" style="mso-hide:all;"><span>Yes, it's me!</span></a>
                        </td>
                    </tr>
                </table>
                <!--~[if (gte mso 9)|(IE)~]></td></tr></table>
                <!~[endif~]-->
            </td>
        </tr>
        <tr>
            <td bgcolor="#f3f3f3" align="center" style="padding: 2px 10px 0px 10px; border-radius: 2px 2px 0px 0px;">
                <!--~[if (gte mso 9)|(IE)~]>
                    <table align="center" border="0" cellspacing="0" cellpadding="0" width="600"><tr><td align="center" valign="top" width="600">
                <!~[endif~]-->
                <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
                    <tr>
                        <td bgcolor="#ffffff" align="left" valign="top" style="padding: 32px 30px 16px 30px; border-radius: 0px 0px 2px 2px;">
                            <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #333333; font-size: 16px; font-weight: 400; line-height: 24px; margin: 0px 0px 0px 0px;">If the button doesn't work, please copy and paste this code into the verification form.</p>
                        </td>
                    </tr>
                    <tr>
                        <td bgcolor="#ffffff" align="center" valign="top" style="padding: 0px 30px 40px 30px; border-radius: 0px 0px 2px 2px;">
                            <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 100%;">
                                <tr>
                                    <td bgcolor="#f3f3f3" align="center" valign="top" style="padding: 16px 16px 16px 16px; border-radius: 0px 0px 2px 2px;">
                                        <p style="font-family: 'IBM Plex Sans', Arial, sans-serif; color: #ff444f; font-size: 16px; font-weight: bold; line-height: 24px; margin: 0px 0px 0px 0px;">[_2]</p>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                </table>
                <!--~[if (gte mso 9)|(IE)~]>
                    </td></tr></table>
                <!~[endif~]-->
            </td>
        </tr>      
    )    
);

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
    my $email            = $args->{email};

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
    return {
        account_opening_new => sub {
            my ($message, $subject);

            if ($brand->name eq 'deriv') {
                $subject = localize('Verify your account for Deriv');
                $message = localize($deriv_content{account_opening_new}, _build_verification_url('signup', $args));
            } else {
                $subject = localize('Verify your email address - [_1]', $website_name);
                $message =
                    $verification_uri
                    ? localize(
                    '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Click the following link to verify your account:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    _build_verification_url('signup', $args),
                    $website_name
                    )
                    : localize(
                    '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Enter the following verification token into the form to create an account: <p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $code, $website_name
                    );
            }

            return {
                subject => $subject,
                message => $message
            };
        },
        account_opening_existing => sub {
            my ($message, $subject);

            if ($brand->name eq 'deriv') {
                $subject = localize('This email is taken');
                $message = localize($deriv_content{account_opening_existing}, $email);
            } elsif ($source == 1) {
                $subject = localize('Duplicate email address submitted - [_1]', $website_name);
                $message = '<div style="line-height:200%;color:#333333;font-size:15px;">'
                    . localize(
                    '<p>It seems that you tried to sign up with an email address that\'s already in the [_2] system.</p><p>You may have</p><ul><li>Previously signed up with [_2] using the same email address, or</li><li>Signed up with another trading application that uses [_2] technology.</li></ul><p>If you have forgotten your password, please <a href="[_1]">reset your password</a> now to access your account.</p><p>If this wasn\'t you, please ignore this email.</p><p style="color:#333333;font-size:15px;">Regards,<br/>[_2]</p>',
                    $password_reset_url, $website_name,
                    ) . '</div>';
            } else {
                $subject = localize('Duplicate email address submitted to [_1] (powered by [_2])', $app_name, $website_name);
                $message = '<div style="line-height:200%;color:#333333;font-size:15px;">'
                    . localize(
                    '<p>[_3] is one of many trading applications powered by [_2] technology. It seems that you tried to sign up with an email address that\'s already in the [_2] system.</p><p>You may have</p><ul><li>Previously signed up with [_3] using the same email address, or</li><li>Signed up with another trading application that uses [_2] technology.</li></ul><p>If you have forgotten your password, please <a href="[_1]">reset your password</a> now to access your account.</p><p>If this wasn\'t you, please ignore this email.</p><p style="color:#333333;font-size:15px;">Regards,<br/>[_2]</p>',
                    $password_reset_url, $website_name, $app_name)
                    . '</div>';
            }

            return {
                subject => $subject,
                message => $message
            };
        },
        payment_withdraw => sub {
            my $type_call = shift;
            my ($message, $subject);
            
            if ($brand->name eq 'deriv') {
                $subject = localize('Verify your withdrawal request - [_1]', $website_name);
                $message = localize($deriv_content{payment_withdraw}, _build_verification_url('payment_withdraw', $args), $code);                
            }
            else {

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
                    
                $subject = localize('Verify your withdrawal request - [_1]', $website_name);
                $message = $type_call eq 'payment_withdraw' ? $payment_withdraw : $payment_withdraw_agent;
            }
            
            return {
                subject => $subject,
                message => $message
            };
        },
        reset_password => sub {
            return {
                subject => localize('Reset your [_1] account password', $website_name),

                message => $verification_uri
                ? (
                    $has_social_signup
                    ? localize(
                        '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. If it was you, we\'d be glad to help.</p><p>Before we proceed, we noticed you are logged in using your (Google/Facebook) account. Please note that if you reset your password, your social account login will be deactivated. If you wish to keep your social account login, you would need to remember your (Google/Facebook) account password.</p><p>If you\'re ready, <a href="[_2]">reset your password now.<a></p><p>Not you? Unsure? <a href="[_4]">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                        $user_name || 'there',
                        _build_verification_url('reset_password', $args),
                        $website_name,
                        $contact_url,
                        )
                    : localize(
                        '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. If it was you, you may <a href="[_2]">reset your password now.<a></p><p>Not you? Unsure? <a href="[_4]">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                        $user_name || 'there',
                        _build_verification_url('reset_password', $args),
                        $website_name,
                        $contact_url,
                    ))
                : localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Hello [_1],</p><p>We received a request to reset your password. Please use the token below to create your new password.</p><p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_2]</span></p><p>Not you? Unsure? <a href="[_4]">Please let us know right away.</a></p><p style="color:#333333;font-size:15px;">Thank you for trading with us.<br/>[_3]</p>',
                    $user_name || 'there',
                    $code,
                    $website_name,
                    $contact_url,
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
