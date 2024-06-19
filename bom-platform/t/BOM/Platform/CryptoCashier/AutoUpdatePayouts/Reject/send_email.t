use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;
use Email::Sender::Transport::SMTP;
use Email::Stuffer;

my $mock_email_module = Test::MockModule->new('Email::Stuffer');
my $mock_reject       = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject');

my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => 'cr');

my $args = {};

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject::send_email' => sub {

    subtest 'returns error message if required environment variable are not defined' => sub {
        my $exc = $auto_reject_obj->send_email(%$args);

        like $exc, qr/The following required environment variables are empty: MAIL_HOST, MAIL_PORT, RECIPIENT_EMAIL, SENDER_EMAIL/,
            'error msg is correct';
    };

    subtest 'return error if email is not successfully send' => sub {
        $ENV{MAIL_HOST}       = 'dummy';
        $ENV{MAIL_PORT}       = 1234;
        $ENV{RECIPIENT_EMAIL} = 'dummy@dummy.com';
        $ENV{SENDER_EMAIL}    = 'dummy@dummy.com';

        my $exc = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->send_email(%$args);

        like $exc, qr/Failed to send the email at email address/, 'error msg is correct';

        $mock_email_module->unmock_all();

    };

    subtest 'email send successfully' => sub {
        $ENV{MAIL_HOST}       = 'dummy';
        $ENV{MAIL_PORT}       = 1234;
        $ENV{RECIPIENT_EMAIL} = 'dummy@dummy.com';
        $ENV{SENDER_EMAIL}    = 'dummy@dummy.com';
        $mock_email_module->mock(
            send => sub {
                return 1;
            });

        my $exc = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->send_email(%$args);

        like $exc, qr/Mail sent successfully at email address /, 'error msg is correct';

        $mock_email_module->unmock_all();

    };

    subtest 'Returns the error if something unexpected happens' => sub {
        $ENV{MAIL_HOST}       = 'dummy';
        $ENV{MAIL_PORT}       = 'dummy port';
        $ENV{RECIPIENT_EMAIL} = 'dummy@dummy.com';
        $ENV{SENDER_EMAIL}    = 'dummy@dummy.com';
        $mock_email_module    = undef;
        my $exc = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->send_email(%$args);

        like $exc, qr/Error sending email/, 'error msg is correct';

    }

};

done_testing;
