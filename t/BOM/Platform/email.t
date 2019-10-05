use strict;
use warnings;
use Test::More;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings qw(warning);
use BOM::Platform::Context qw(request);
use Email::Address::UseXS;
use Email::MIME::Attachment::Stripper;
use Path::Tiny;
use File::Basename;

BEGIN { use_ok('BOM::Platform::Email', qw(send_email)); }

my $transport      = Email::Sender::Transport::Test->new;
my $mocked_stuffer = Test::MockModule->new('Email::Stuffer');
$mocked_stuffer->mock(
    'send_or_die',
    sub {
        my $self = shift;
        $self->transport($transport);
        $mocked_stuffer->original('send_or_die')->($self, @_);
    });

my $args = {};
my $result;
local $ENV{SKIP_EMAIL};
subtest 'args' => sub {
    like(warning { $result = send_email($args); }, qr/missing/, 'no email address');
    ok(!$result, 'failed because no to email');
    $args->{to} = 'test@test.com';
    like(warning { $result = send_email($args); }, qr/missing/, 'no from email address');
    ok(!$result, 'failed because no from email');
    $args->{from} = 'from@test.com';
    like(warning { $result = send_email($args); }, qr/missing/, 'no subject');
    ok(!$result, 'failed because no subject');
    local $ENV{SKIP_EMAIL} = 1;
    $args->{subject} = 'Test subject';
    ok(send_email($args), 'result success but in fact not email not sent');
    is scalar($transport->deliveries), 0, 'not called yet';
    local $ENV{SKIP_EMAIL} = 0;
    $args->{to} = 'hello';
    like(warning { $result = send_email($args); }, qr/erroneous email address/, 'bad email address');
    ok(!$result, 'failed because of bad email address');
    done_testing();
};

subtest 'support address' => sub {
    $args->{to} = 'test@test.com';
    my $brand = request()->brand;
    $args->{from} = $brand->emails('support');
    ok(send_email($args));
    my @deliveries = $transport->deliveries;
    is(scalar @deliveries, 1, 'one mail sent');
    is_deeply($deliveries[-1]{successes}, ['test@test.com'], 'send email ok');
    is $deliveries[-1]{email}->get_header('From'), '"Binary.com" <support@binary.com>', 'From is rewrote';

};

subtest 'no use template' => sub {
    $args->{subject} = 'hello           world';
    $args->{message} = [qw(line1 line2)];
    ok(send_email($args));
    my @deliveries = $transport->deliveries;
    my $email      = $deliveries[-1]{email};
    is $email->get_body, "line1\r\nline2=\r\n", 'message joined';
    is $email->get_header('Subject'), 'hello world', 'remove continuous spaces';
};

subtest 'with template' => sub {
    $args->{use_email_template} = 1;
    ok(send_email($args));
    my @deliveries = $transport->deliveries;
    my $email      = $deliveries[-1]{email};
    like $email->get_body, qr/line1\r\nline2/s, 'text not turn to html';
    like $email->get_body, qr/<html>/s,         'use template';
    $args->{email_content_is_html} = 1;
    ok(send_email($args));
    @deliveries = $transport->deliveries;
    $email      = $deliveries[-1]{email};
    like $email->get_body, qr/line2<br \/>/s, 'text turned to html';
    $args->{skip_text2html} = 1;
    ok(send_email($args));
    @deliveries = $transport->deliveries;
    $email      = $deliveries[-1]{email};
    like $email->get_body, qr/line1\r\nline2/s, 'text not turn to html';

};

subtest attachment => sub {
    my $att1 = '/tmp/attachment1.csv';
    path($att1)->spew('This is attachment1');
    $args->{attachment} = $att1;
    ok(send_email($args));
    my @deliveries  = $transport->deliveries;
    my $email       = $deliveries[-1]{email}->object;
    my @attachments = Email::MIME::Attachment::Stripper->new($email)->attachments;
    is(scalar @attachments,       2);
    is($attachments[1]{filename}, basename($att1));
    my $att2 = '/tmp/attachment2.csv';
    path($att2)->spew('This is attachment2');
    $args->{attachment} = [$att1, $att2];
    ok(send_email($args));
    @deliveries  = $transport->deliveries;
    $email       = $deliveries[-1]{email}->object;
    @attachments = Email::MIME::Attachment::Stripper->new($email)->attachments;
    is(scalar @attachments,       3);
    is($attachments[1]{filename}, basename($att1));
    is($attachments[2]{filename}, basename($att2));
};

done_testing();
