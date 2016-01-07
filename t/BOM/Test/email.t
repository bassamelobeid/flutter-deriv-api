use strict;
use warnings;

use Test::More (tests => 10);
use Test::Exception;
use Mail::Sender;

BEGIN { use_ok('BOM::Test::Email', qw(get_email_by_address_subject clear_mailbox)); }
my $mailbox = $BOM::Test::Email::mailbox;
ok(-e $mailbox, "mailbox created");
my $address = 'test@test.com';
my $subject = "test mail sender";
my $body    = "hello, this is just for test";

#send email
lives_ok {
    Mail::Sender->new({
            smtp      => 'localhost',
            from      => "travis",
            to        => $address,
            ctype     => 'text/html',
            charset   => 'UTF-8',
            encoding  => "quoted-printable",
            on_errors => 'die',
        }
        )->Open({
            subject => $subject,
        })->SendEnc($body)->Close();
};


#test arguments
throws_ok { get_email_by_address_subject() } qr/Need email address and subject regexp/, 'test arguments';
throws_ok { get_email_by_address_subject(email => $address) } qr/Need email address and subject regexp/, 'test arguments';
throws_ok { get_email_by_address_subject(email => $address, subject => $subject) } qr/Need email address and subject regexp/, 'test arguments';
throws_ok { get_email_by_address_subject(subject => qr/$subject/) } qr/Need email address and subject regexp/, 'test arguments';

my %msg;
lives_ok { %msg = get_email_by_address_subject(email => $address, subject => qr/$subject/) } 'get email';
like($msg{body}, qr/$body/, 'get correct email');
clear_mailbox();
ok(-z $mailbox, "mailbox truncated");

