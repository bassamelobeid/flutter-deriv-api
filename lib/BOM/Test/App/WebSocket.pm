package BOM::Test::App::WebSocket;

use strict;
use warnings;
use Test::More;
use Role::Tiny;

use Encode;
use JSON::MaybeXS;
use BOM::Test::Helper qw/build_wsapi_test/;

my $json = JSON::MaybeXS->new;

sub build_test_app {
    my ($self, $args) = @_;
    return build_wsapi_test($args, {}, sub { _store_stream_data($self->{streams}, @_) });
}

sub test_schema {
    my ($self, $req_params, $expected_json_schema, $descr, $should_be_failed) = @_;

    my $t = $self->{t};
    $t = $t->send_ok({json => $req_params});
    my $i         = 0;
    my $max_times = 15;
    my $result;
    my @subscribed_streams_ids = map { $_->{id} } values %{$self->{streams}};
    while ($i++ < $max_times && !$result) {
        $t->message_ok;
        my $message = $json->decode(Encode::decode_utf8($t->message->[1]));
        # skip subscribed stream's messages
        next
            if ref $message->{$message->{msg_type}} eq 'HASH'
            && grep { $message->{$message->{msg_type}}->{id} && $message->{$message->{msg_type}}->{id} eq $_ } @subscribed_streams_ids;
        $result = $message;
    }
    if (!$result) {
        diag("There isn't testing message in last $max_times stream messages");
    }

    $self->_test_schema($result, $expected_json_schema, $descr, $should_be_failed);

    return $result;
}

sub test_schema_last_stream_message {
    my ($self, $stream_id, $expected_json_schema, $descr, $should_be_failed) = @_;

    die 'wrong stream_id' unless $self->{streams}->{$stream_id};

    my $result;
    my @stream_data = @{$self->{streams}->{$stream_id}->{stream_data} || []};
    $result = $stream_data[-1] if @stream_data;

    $self->_test_schema($result, $expected_json_schema, $descr, $should_be_failed);
    return;
}

sub start_stream {
    my ($self, $test_stream_id, $stream_id, $call_name) = @_;

    die 'wrong stream response' unless $stream_id;
    die 'already exists same stream_id' if $self->{streams}->{$test_stream_id};
    $self->{streams}->{$test_stream_id}->{id}        = $stream_id;
    $self->{streams}->{$test_stream_id}->{call_name} = $call_name;
    return;
}

sub _store_stream_data {
    my ($streams, undef, $result) = @_;
    my $call_name;
    for my $stream_id (keys %$streams) {
        my $stream = $streams->{$stream_id};
        $call_name = $stream->{call_name} if exists $result->{$stream->{call_name}};
    }
    return unless $call_name;
    for my $stream_id (keys %$streams) {
        push @{$streams->{$stream_id}->{stream_data}}, $result
            if $result->{$call_name}->{id} && $result->{$call_name}->{id} eq $streams->{$stream_id}->{id};
    }
    return;
}

1;
