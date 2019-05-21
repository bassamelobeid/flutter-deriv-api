use strict;
use warnings;

use BOM::RPC::v3::EmailVerification qw(email_verification);
use Test::Most;
use Email::Stuffer::TestLinks;

my $code             = 'RANDOM_CODE';
my $website_name     = 'My website name';
my $verification_uri = 'https://www.example.com/verify';
my $language         = 'EN';
my $source           = 1;

sub get_verification_uri {
    my $action = shift;

    return "$verification_uri?action=$action&lang=EN&code=$code";
}

my $messages = {
    reset_password => {
        with_link =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by clicking the link below:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
        with_token =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
    },
    account_opening_new => {
        with_link =>
            '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Click the following link to verify your account:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
        with_token =>
            '<p style="font-weight: bold;">Thank you for signing up for a virtual account!</p><p>Enter the following verification token into the form to create an account: <p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
    },
    payment_withdraw => {
        with_link =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the link below:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
        with_token =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment withdrawal form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
    },
    payment_agent_withdraw => {
        with_link =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by clicking the link below:</p>[_1]<p>If clicking the link above doesn\'t work, please copy and paste the URL in a new browser window instead.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
        with_token =>
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment agent withdrawal form:<p><span id="token" style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
    },
};

sub get_verification_message {
    my ($message_name, $action) = @_;

    my $uri               = get_verification_uri($action)      if $action;
    my $verification_link = "<p><a href=\"$uri\">$uri</a></p>" if $action;

    my $verification_way = $action ? $verification_link : $code;

    my $message = $messages->{$message_name}->{$action ? 'with_link' : 'with_token'};

    $message =~ s/\[_1\]/$verification_way/g;
    $message =~ s/\[_2\]/$website_name/g;

    return $message;
}

sub get_verification {
    my $with_link = shift;

    return email_verification({
        code         => $code,
        website_name => $website_name,
        language     => $language,
        source       => $source,
        ($with_link ? (verification_uri => $verification_uri) : ()),
    });
}

subtest 'Account Opening (new) Verification' => sub {
    my $verification = get_verification();

    is $verification->{account_opening_new}->()->{subject}, "Verify your email address - $website_name", 'Account opening subject';
    is $verification->{account_opening_new}->()->{message}, get_verification_message('account_opening_new'), 'Account opening with token';

    $verification = get_verification(1);

    is $verification->{account_opening_new}->()->{message}, get_verification_message('account_opening_new', 'signup'),
        'Account opening with verification URI';
};

subtest 'Payment Withdraw Verification' => sub {
    my $verification = get_verification();

    is $verification->{payment_withdraw}->('payment_withdraw')->{subject}, "Verify your withdrawal request - $website_name",
        'Payment Withdraw subject';
    is $verification->{payment_withdraw}->('payment_withdraw')->{message}, get_verification_message('payment_withdraw'),
        'Payment Withdraw with token';
    is $verification->{payment_withdraw}->('payment_agent_withdraw')->{message}, get_verification_message('payment_agent_withdraw'),
        'Payment Agent Withdraw with token';

    $verification = get_verification(1);

    is $verification->{payment_withdraw}->('payment_withdraw')->{message}, get_verification_message('payment_withdraw', 'payment_withdraw'),
        'Payment Withdraw with verification URI';
    is $verification->{payment_withdraw}->('payment_agent_withdraw')->{message},
        get_verification_message('payment_agent_withdraw', 'payment_agent_withdraw'), 'Payment Agent Withdraw with verification URI';
};

subtest 'Password Reset Verification' => sub {
    my $verification = get_verification();

    is $verification->{reset_password}->()->{subject}, "$website_name New Password Request", 'reset password verification subject';
    is $verification->{reset_password}->()->{message}, get_verification_message('reset_password'), 'Password Reset with token';

    $verification = get_verification(1);

    is $verification->{reset_password}->()->{message}, get_verification_message('reset_password', 'reset_password'),
        'Password Reset with verification URI';
};

subtest 'Build Verification  URL' => sub {

    ## no utm params supplied
    my $args = {
        verification_uri => "http://www.fred.com",
        language         => 'Eng',
        code             => "Thisisthecode"
    };
    my $result = BOM::RPC::v3::EmailVerification::_build_verification_url('action_test', $args);
    is($result, 'http://www.fred.com?action=action_test&lang=Eng&code=Thisisthecode', "url creation with no UTM params set correct");

    ## with utm params

    $args = {
        verification_uri   => "http://www.fred.com",
        language           => 'Eng',
        code               => "Thisisthecode",
        utm_source         => "google",
        utm_medium         => 'email',
        utm_campaign       => 'Grand_Opening',
        signup_device      => 'mobile',
        gclid_url          => 'adasd.sd',
        date_first_contact => '20150301',
        affiliate_token    => 'asdasd123',
    };
    $result = BOM::RPC::v3::EmailVerification::_build_verification_url('action_test', $args);
    is(
        $result,
        'http://www.fred.com?action=action_test&lang=Eng&code=Thisisthecode&utm_source=google&utm_campaign=Grand_Opening&utm_medium=email&signup_device=mobile&gclid_url=adasd.sd&date_first_contact=20150301&affiliate_token=asdasd123',
        "url creation with UTM params set correct"
    );
};

done_testing();
