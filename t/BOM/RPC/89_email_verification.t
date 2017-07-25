use strict;
use warnings;

use BOM::RPC::v3::EmailVerification qw(email_verification);
use Test::Most;

my $code = 'RANDOM_CODE';
my $website_name = 'My website name';
my $verification_uri = 'https://www.example.com/verify';

sub get_verification_uri {
    my $action = shift;
    
    return "$verification_uri?action=reset_password&code=$code";
}

my $messages = {
    reset_password => {
        with_link => '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by clicking the below link:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
        with_token => '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
    },
};

sub get_verification_message {
    my ($action, $with_link) = @_;
    my $uri = get_verification_uri($action);
    my $verification_link = "<p><a href=\"$uri\">$uri</a></p>";
    
    my $verification_way = $with_link ? $verification_link : $code;
    
    my $message = $messages->{$action}->{$with_link ? 'with_link' : 'with_token'};

    $message =~ s/\[_1\]/$verification_way/g;
    $message =~ s/\[_2\]/$website_name/g;
    
    return $message;
}

subtest 'Password Reset Verification' => sub {
    my $verification = email_verification({
        code => $code,
        website_name => $website_name,
    });
    
    is $verification->{reset_password}->()->{subject}, "$website_name New Password Request", 'reset password verification subject';
    is $verification->{reset_password}->()->{message}, get_verification_message('reset_password'), 'Password Reset with token';
    
    $verification = email_verification({
        code => $code,
        website_name => $website_name,
        verification_uri => $verification_uri,
    });
    
    is $verification->{reset_password}->()->{message}, get_verification_message('reset_password', 1), 'Password Reset with verification URI';
};

done_testing();