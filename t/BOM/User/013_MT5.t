use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Warn;
use Test::Exception;
use Test::MockModule;

use JSON::MaybeUTF8 qw(:v1);
use Socket qw(:crlf);
use IO::Async::Loop;
use IO::Async::Stream;
use BOM::MT5::User::Manager;

my $loop           = IO::Async::Loop->new;
my $mocked_loop    = new Test::MockModule('IO::Async::Loop');
my $mocked_stream  = new Test::MockModule('IO::Async::Stream');
my $mocked_manager = new Test::MockModule('BOM::MT5::User::Manager');

$mocked_loop->mock(
    'SSL_connect',
    sub {
        return Future->done(IO::Async::Stream->new);
    });

subtest 'MT5 Manager Tests' => sub {

    subtest '_connect' => sub {
        my $manager = BOM::MT5::User::Manager->new;

        $loop->add($manager);

        my $connection = $manager->_connected->get;
        ok(defined $manager->{_stream},                  '_connect should configure a stream');
        ok(defined $manager->{_connected},               'connection should be reusable');
        ok(ref $manager->{_pending_requests} eq 'ARRAY', 'pending request queure should be initialized');

        $loop->remove($manager);
    };

    subtest '_parse_message' => sub {
        my $manager = BOM::MT5::User::Manager->new;

        my $message = '{"text": "Hello World"}';
        my $message_len = pack('n', length $message);

        my $buffer     = '';
        my $buffer_ref = \$buffer;

        is($manager->_parse_message($buffer_ref), undef, 'return undef if buffer contain less than 2 bytes');

        $$buffer_ref = $message_len . '{"te"';    #incomplete buffer
        is($manager->_parse_message($buffer_ref), undef, 'return undef if buffer does not contain the required length');

        $$buffer_ref = $message_len . $message;    #complete buffer without CRLF
        is($manager->_parse_message($buffer_ref), undef, 'return undef if buffer is complete but waiting for CRLF');

        $$buffer_ref = $message_len . $message . '14';    #framing error

        my $cleanup_called = 0;
        $mocked_manager->mock(
            "_clean_up",
            sub {
                $cleanup_called = 1;
            });
        warnings_exist {
            $manager->_parse_message($buffer_ref);
            is($cleanup_called, 1, '_clean_up should be triggered if framing error detected');
        }
        [qr/Framing error/], 'Expected error is throwen';

        $$buffer_ref = $message_len . $message . "\r\n";    #complete parasable message
        my $parsed_message = $manager->_parse_message($buffer_ref);
        is($parsed_message->{text}, 'Hello World', 'parse message successfully');
    };

    subtest '_send_message' => sub {
        my $manager = BOM::MT5::User::Manager->new;
        $loop->add($manager);
        $mocked_stream->mock(
            'write',
            sub {
                my ($self, $message) = @_;
                my $message_length = unpack 'n', (substr $message, 0, 2, '');
                my $message_decoded = decode_json_utf8(substr($message, 0, $message_length, ''));

                ok($message_length > 0, 'message length shoule be set');
                is($message_decoded->{text}, 'Hello World', 'message was encoded correctly');
                ok($message_decoded->{request_id}, 'request id has been set');
                ok($message_decoded->{api_key},    'MT5 shared secret has been set');
                is($message,                         $CRLF, 'message trailed with CRLF');
                is(@{$manager->{_pending_requests}}, 1,     'request have been queued');
            });

        my $request = $manager->_send_message({text => 'Hello World'}, "1");

        $loop->remove($manager);
    };

    subtest 'timeout guards' => sub {
        my $manager = BOM::MT5::User::Manager->new;
        $loop->add($manager);

        $mocked_manager->mock(
            '_connect',
            sub {
                return $loop->timeout_future(after => 300);
            });

        dies_ok {
            $manager->_connected->get;
        }
        '_connected should timeout if there is no response from server';

        $mocked_manager->unmock('_connect');

        $mocked_stream->mock(
            'write',
            sub {    # let the write operation success but on_read will never called
                return 1;
            });

        dies_ok {
            $manager->_send_message({text => 'Hello World'})->get;
        }
        '_send_message should timeout if there is no response from server';

        $loop->remove($manager);
    };

    subtest 'adjust_balance' => sub {
        $mocked_manager->mock(
            '_send_message',
            sub {
                return Future->done({
                        success => 0,
                        error   => {
                            err_type  => 'MT5',
                            err_code  => 3000,
                            err_descr => 'fake error'
                        }});
            });
        my $manager = BOM::MT5::User::Manager->new;

        dies_ok {
            $manager->adjust_balance(undef, 1, 'comment')->get;
        }
        'adjust_balance should be called with valid login';

        dies_ok {
            $manager->adjust_balance(1233, 0, 'comment')->get;
        }
        'adjust_balance should be called with valid amount';

        dies_ok {
            $manager->adjust_balance(1233, 10, '')->get;
        }
        'adjust_balance should be called with a comment';

        my $result = $manager->adjust_balance(1233, 10, 'comment')->get;

        is($result->{success},    0,    'success should be 0 if so returned by MT5');
        is($result->{error_code}, 3000, 'error code shoule be carried as well');

    };
};

done_testing();
