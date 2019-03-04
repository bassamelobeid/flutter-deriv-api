package BOM::MT5::User::Manager;

use strict;
use warnings;
use 5.014;

use curry;
use Encode;
use YAML ();
use JSON::MaybeUTF8 qw(:v1);
use Try::Tiny;
use Data::UUID;

use IO::Async::Stream;
use IO::Async::SSL;
use IO::Socket::SSL qw(SSL_VERIFY_PEER);

use Socket qw(:crlf);

use Moo;
use parent 'IO::Async::Notifier';

use constant SSL_VERSION   => 'TLSv12';
use constant TIMEOUT_DELAY => 5;

my $mt5_config;

BEGIN {
    try {
        $mt5_config = YAML::LoadFile('/etc/rmg/mt5webapi.yml')->{server};
    }
    catch {
        die "cannot load config in /etc/rmg/mt5webapi.yml";
    };
}

sub _connect {
    my $self = shift;
    return $self->loop->SSL_connect(
        host               => $mt5_config->{manager_bridge_host},
        service            => $mt5_config->{manager_bridge_port},
        socktype           => 'stream',
        SSL_version        => SSL_VERSION,
        SSL_startHandshake => 0,
        SSL_verify_mode    => SSL_VERIFY_PEER,
        SSL_ca_file        => $mt5_config->{ca_cert},
        SSL_cert_file      => $mt5_config->{ssl_cert},
        SSL_key_file       => $mt5_config->{ssl_key},
        )->then(
        sub {
            my ($stream)      = @_;
            my $error_handler = $self->curry::weak::_clean_up;
            my $read_handler  = $self->$curry::weak(
                sub {
                    my ($self, $stream, $buffer_ref, $eof) = @_;
                    while (my $message = $self->_parse_message($buffer_ref)) {
                        $self->_resolve_request_future($message);
                    }

                    if ($eof) {
                        # server might close the connection
                        $self->_clean_up;
                        return 0;
                    }

                    return 0;
                });

            $stream->configure(
                on_read_error  => $error_handler,
                on_write_error => $error_handler,
                on_read        => $read_handler,
            );

            $self->{_stream} = $stream;
            $self->add_child($stream);
            $self->{_pending_requests} = [];

            return Future->done(1);
        }
        )->catch(
        sub {
            warn "Cannot connect to MT5 Manager: $_[0]";
            return Future->fail('connection error');
        });
}

sub _connected {
    my $self = shift;
    return $self->{_connected} ||= Future->wait_any($self->loop->timeout_future(after => TIMEOUT_DELAY), $self->_connect);
}

sub _resolve_request_future {
    my ($self, $message) = @_;

    return shift(@{$self->{_pending_requests}})->done($message);
}

sub _get_request_id {
    return Data::UUID->new()->create_str();
}

sub _clean_up {
    my $self = shift;
    $_->fail('connection closed') for @{$self->{_pending_requests}};
    delete $self->{_pending_requests};

    $self->{_stream}->close if defined $self->{_stream};
    delete $self->{_connected};

    return 1;
}

sub _send_message {
    my ($self, $message, $request_UUID) = @_;
    return $self->_connected->then(
        sub {
            $message->{request_id} = $request_UUID;
            $message->{api_key}    = $mt5_config->{api_key};
            my $message_string = encode_json_utf8($message);

            # MT5 Managers command should be prepended with lenght and ended with '\r\n'
            my $message_encoded = pack("n", length($message_string)) . "$message_string$CRLF";
            push @{$self->{_pending_requests}}, my $f = $self->loop->new_future;
            $self->{_stream}->write($message_encoded);

            return Future->wait_any($f, $self->loop->timeout_future(after => TIMEOUT_DELAY));
        });
}

sub _parse_message {
    my ($self, $buffer_ref) = @_;
    return undef unless length $$buffer_ref >= 2;
    my $message_length = unpack "n", $$buffer_ref;

    return undef unless length $$buffer_ref >= $message_length + 4;    # 2 bytes for message length and 2 bytes for CRLF
    substr $$buffer_ref, 0, 2, '';
    my $message_raw = substr($$buffer_ref, 0, $message_length, "");

    $$buffer_ref =~ s{^\Q$CRLF}{} or do {                              # framing error
        $self->_clean_up;
        warn "Framing error while parsing MT5 response";
    };

    return decode_json_utf8($message_raw);
}

sub adjust_balance {
    my ($self, $login, $amount, $comment, $request_UUID) = @_;
    return Future->fail('MT5 user id is required')     unless $login;
    return Future->fail('Transfer amount is required') unless $amount;
    return Future->fail('Comment is mandatory')        unless length $comment;

    my $message = {
        method => 'adjust_balance',
        args   => [$login + 0, $amount + 0, $comment],
    };

    return $self->_send_message($message, $request_UUID)->then(
        sub {
            my ($message) = @_;
            return Future->done($message) if $message->{success};
            return Future->done({
                    success    => 0,
                    error      => 'internal error',
                    error_code => $message->{error}->{err_code}});
        });
}

1;
