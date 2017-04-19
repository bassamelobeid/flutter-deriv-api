use strict;
use warnings;
use Test::More;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings qw(warning);
use Brands;
use BOM::Platform::Context qw(request);
use Email::Folder::Search;

BEGIN { use_ok('BOM::Platform::Email', qw(send_email)); }

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;
local $ENV{SKIP_EMAIL} = 1;
my $args = {};
my $result;
subtest 'args' => sub {
    $mailbox->clear;
    like(warning { $result = send_email($args); }, qr/missed/, 'no email address');
    ok(!$result, 'failed because no to email');
    $args->{to} = 'test@test.com';
    like(warning { $result = send_email($args); }, qr/missed/, 'no from email address');
    ok(!$result, 'failed because no from email');
    $args->{from} = 'from@test.com';
    like(warning { $result = send_email($args); }, qr/missed/, 'no subject');
    ok(!$result, 'failed because no subject');
    local $ENV{SKIP_EMAIL} = 1;
    $args->{subject} = "Test subject";
    ok(send_email($args), 'result success but in fact not email not sent');
    my @msgs = $mailbox->search(
        email   => $args->{to},
        subject => qr/$args->{subject}/,
    );
    is scalar(@msgs), 0, "not called yet";
    local $ENV{SKIP_EMAIL} = 0;
    $args->{to} = "hello";
    like(warning { $result = send_email($args); }, qr/erroneous email address/, 'bad email address');
    ok(!$result, 'failed because of bad email address');
    done_testing();
};

subtest 'support address' => sub {
    $mailbox->clear;
    $args->{to} = 'test@test.com';
    my $brand = Brands->new(name => request()->brand);
    $args->{from} = $brand->emails('support');
    ok(send_email($args));
    my @msgs = $mailbox->search(
        email   => 'test@test.com',
        subject => qr/$args->{subject}/,
    );
    is scalar(@msgs), 1, "one mail sent";
    is $msgs[0]{from}, '"Binary.com" <support@binary.com>', 'From is rewrote';
};

subtest 'no use template' => sub {
    $mailbox->clear;
    $args->{subject} = "hello           world";
    $args->{message} = [qw(line1 line2)];
    ok(send_email($args));
    my @msgs = $mailbox->search(
        email   => 'test@test.com',
        subject => qr/hello\s+world/,
    );
    is scalar(@msgs), 1, "one mail sent";
    like $msgs[0]->{body},    qr/line1\nline2=\n/s, 'message joined';
    is $msgs[0]->{subject}, "hello world",         'remove continuous spaces';
   diag `cat /tmp/default.mailbox`; 
};

subtest 'with template' => sub {
    $mailbox->clear;
    $args->{use_email_template} = 1;
    ok(send_email($args));
    my @msgs = $mailbox->search(
        email   => 'test@test.com',
        subject => qr/hello\s+world/,
    );
    is scalar(@msgs), 1, "one mail sent";
    like $msgs[0]->{body}, qr/line1\nline2/s, "text not turn to html";
    like $msgs[0]->{body}, qr/<html>/s,         "use template";
    $args->{email_content_is_html} = 1;
    $mailbox->clear;
    ok(send_email($args));
    @msgs = $mailbox->search(
        email   => 'test@test.com',
        subject => qr/hello\s+world/,
    );
    is scalar(@msgs), 1, "one mail sent";
    like $msgs[0]->{body}, qr/line2<br \/>/s, "text turned to html";

    $mailbox->clear;
    $args->{skip_text2html} = 1;
    ok(send_email($args));
    @msgs = $mailbox->search(
        email   => 'test@test.com',
        subject => qr/hello\s+world/,
    );
    is scalar(@msgs), 1, "one mail sent";
    like $msgs[0]->{body}, qr/line1\nline2/s, "text not turn to html";
};

done_testing();
