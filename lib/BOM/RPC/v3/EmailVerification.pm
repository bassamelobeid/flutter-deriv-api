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

    my $gen_verify_button = sub {
        my $action = shift;
        my $uri    = "$verification_uri?action=$action&code=$code";

        return "<p><a href=\"$uri\">$uri</a></p>";
    };

    return {
        account_opening_new => sub {
            return {
                subject => localize('Verify your email address - [_1]', $website_name),
                message => $verification_uri
                ? localize(
                    '<p style="font-weight: bold;">Thanks for signing up for a virtual account!</p><p>Click the following link to verify your account:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $gen_verify_button->('signup'),
                    $website_name
                    )
                : localize(
                    '<p style="font-weight: bold;">Thanks for signing up for a virtual account!</p><p>Enter the following verification token into the form to create an account: <p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $code,
                    $website_name
                ),
            };
        },
        account_opening_existing => sub {
            return {
                subject => localize('A Duplicate Email Address Has Been Submitted - [_1]', $website_name),
                message => '<div style="line-height:200%;color:#333333;font-size:15px;">'
                    . localize(
                    '<p>Dear Valued Customer,</p><p>It appears that you have tried to register an email address that is already included in our system. If it was not you, simply ignore this email, or contact our customer support if you have any concerns.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_1]</p>',
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
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the below link:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                $gen_verify_button->('payment_withdraw'),
                $website_name
                )
                : localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment withdrawal form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                $code, $website_name
                );

            my $payment_withdraw_agent =
                $verification_uri
                ? localize(
                '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the below link:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                $gen_verify_button->('payment_agent_withdraw'),
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
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by clicking the below link:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $gen_verify_button->('reset_password'),
                    $website_name
                    )
                : localize(
                    '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                    $code,
                    $website_name
                ),
            };
        }
    };
};

@ISA = qw(Exporter);
@EXPORT_OK = qw(email_verification);

1;