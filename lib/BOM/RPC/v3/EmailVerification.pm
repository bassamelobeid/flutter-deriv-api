package BOM::RPC::v3::EmailVerification;

use strict;
use warnings;

use Exporter;
use vars qw(@ISA @EXPORT_OK);
use BOM::Platform::Context qw(localize);

sub email_verification {
    my $args = shift;

    my $code             = $args->{code};
    my $website_name     = $args->{website_name};
    my $verification_uri = $args->{verification_uri};
    my $language         = $args->{language};
    my $source           = $args->{source};
    my $app_name         = $args->{app_name};

    my $gen_verify_link = sub {
        my $action = shift;
        return "$verification_uri?action=$action&lang=$language&code=$code";
    };

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
                    $gen_verify_link->('signup'),
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
                $gen_verify_link->('payment_withdraw'),
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
                $gen_verify_link->('payment_agent_withdraw'),
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
                subject => localize('[_1] New Password Request', $website_name),
                message => $verification_uri
                ? localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by clicking the link below:</p><p><a href="[_1]">[_1]</a></p><p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $gen_verify_link->('reset_password'),
                    $website_name
                    )
                : localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
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
                    $gen_verify_link->('mt5_password_reset'),
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

@ISA       = qw(Exporter);
@EXPORT_OK = qw(email_verification);

1;
