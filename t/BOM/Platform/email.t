use strict;
use warnings;
use Test::More;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings qw(warning);
use Brands;
use BOM::Platform::Context qw(request);

BEGIN { use_ok( 'BOM::Platform::Email', qw(send_email) ); }

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

my $args = {};
my $result;
subtest 'args' => sub {
    $mailbox->clear;
    like( warning { $result = send_email($args); },
        qr/missed/, 'no email address' );
    ok( !$result, 'failed because no to email' );
    $args->{to} = 'test@test.com';
    like( warning { $result = send_email($args); },
        qr/missed/, 'no from email address' );
    ok( !$result, 'failed because no from email' );
    $args->{from} = 'from@test.com';
    like( warning { $result = send_email($args); }, qr/missed/, 'no subject' );
    ok( !$result, 'failed because no subject' );
    local $ENV{SKIP_EMAIL} = 1;
    $args->{subject} = "Test subject";
    ok( send_email($args), 'result success but in fact not email not sent' );
    my @msgs = $mailbox->search(
                                email => 'test@test.com',
                               );
    is scalar(@msgs), 0, "not called yet";
    local $ENV{SKIP_EMAIL} = 0;
    $args->{to} = "hello";
    like(
        warning { $result = send_email($args); },
        qr/erroneous email address/,
        'bad email address'
    );
    ok( !$result, 'failed because of bad email address' );
    done_testing();
};

subtest 'support address' => sub {
    $mailbox->clear;
    $args->{to} = 'test@test.com';
    my $brand = Brands->new( name => request()->brand );
    $args->{from} = $brand->emails('support');
    ok( send_email($args) );
    my @msgs = $mailbox->search(
                                email => 'test@test.com',
                               );
    is scalar(@msgs), 1, "one mail sent";
    diag explain($msgs[0]);
    #  '"Binary.com" <support@binary.com>', 'From is rewrote';

};

subtest 'no use template' => sub {
    $args->{subject} = "hello           world";
    $args->{message} = [qw(line1 line2)];
    ok( send_email($args) );
    my @deliveries = $transport->deliveries;
    my $email = $deliveries[-1]{email};
    is $email->get_body, "line1\r\nline2=\r\n", 'message joined';
    is $email->get_header('Subject'), "hello world", 'remove continuous spaces';
};

subtest 'with template' => sub {
    $args->{use_email_template} = 1;
    ok( send_email($args) );
    my @deliveries = $transport->deliveries;
    my $email = $deliveries[-1]{email};
    like $email->get_body, qr/line1\r\nline2/s, "text not turn to html";
    like $email->get_body, qr/<html>/s,         "use template";
    $args->{email_content_is_html} = 1;
    ok( send_email($args) );
    @deliveries = $transport->deliveries;
    $email = $deliveries[-1]{email};
    like $email->get_body, qr/line2<br \/>/s, "text turned to html";
    $args->{skip_text2html} = 1;
    ok( send_email($args) );
    @deliveries = $transport->deliveries;
    $email = $deliveries[-1]{email};
    like $email->get_body, qr/line1\r\nline2/s, "text not turn to html";

};

done_testing();
