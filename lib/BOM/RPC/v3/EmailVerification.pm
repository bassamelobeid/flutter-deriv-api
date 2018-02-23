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

    my $gen_verify_link = sub {
        my $action = shift;
        return "$verification_uri?action=$action&lang=$language&code=$code";
    };

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
                subject => localize('Duplicate email address submitted - [_1]', $website_name),
                message => '<div style="line-height:200%;color:#333333;font-size:15px;">'
                    . localize(
                    '<p>Dear Valued Customer,</p><p>It appears that you have tried to register an email address that is already included in our system.  <p>You may have:</p><ul><li>Registered with us using the same email in the past, or</li><li>Registered with one of our technology or brokerage partners</li></ul><p>If you\'d like to proceed, please try using a different email address to register your account.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_1]</p>',
                    $website_name
                    )
                    . '</div>'
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
                subject => localize('[_1] New Password Request', $website_name),
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
