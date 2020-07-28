package Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Digest::MD5;
use Net::Async::Webservice::S3;
use Future;
use JSON::MaybeXS qw/decode_json/;
use List::Util qw/first/;

use Binary::WebSocketAPI::Hooks;
use DataDog::DogStatsd::Helper qw(stats_inc);

use constant {
    MAX_CHUNK_SIZE       => 2**17,    # Chunks bigger than 100KB are not allowed
    UPLOAD_TIMEOUT       => 120,      # Effective after the last chunk is arrived
    UPLOAD_STALL_TIMEOUT => 60,       # The greatest acceptable delay between each chunk
};

sub add_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args = $req_storage->{origin_args};

    return $c->wsp_error(
        $req_storage->{msg_type},
        $rpc_response->{error}->{code},
        $rpc_response->{error}->{message_to_client},
        create_error($args, $rpc_response, $req_storage)) if $rpc_response->{error};

    my $current_stash = $c->stash->{document_upload} || {};
    my $upload_id     = generate_upload_id($current_stash);
    my $call_params   = create_call_params($args);

    my $upload_info = {
        %{$call_params},
        file_id           => $rpc_response->{file_id},
        call_type         => $rpc_response->{call_type},
        file_name         => $rpc_response->{file_name},
        file_size         => $args->{file_size},
        page_type         => $args->{page_type},
        md5               => Digest::MD5->new,
        received_bytes    => 0,
        pending_futures   => [],
        upload_id         => $upload_id,
        expected_checksum => $args->{expected_checksum}};

    wait_for_chunks_and_upload_to_s3($c, $upload_info);

    my $stash = {
        %{$current_stash},
        $upload_id => $upload_info,
    };

    $c->stash(document_upload => $stash);

    return create_response(
        $args,
        {
            upload_id => $upload_id,
            call_type => $rpc_response->{call_type},
        });
}

sub document_upload {
    my ($c, $frame) = @_;

    # Handle decoded JSON frames as text frames
    if (eval { decode_json($frame) }) {
        return $c->tx->emit(text => $frame);
    }

    my $upload_info;

    try {
        $upload_info = get_upload_info($c, $frame);
        unless ($upload_info) {
            send_upload_failure($c, $upload_info, 'unknown');
            return;
        }
        upload_chunk($c, $upload_info);
    }
    catch {
        my $e = $@;
        warn "UploadError (app_id: " . $c->app_id . "): $e";
        send_upload_failure($c, $upload_info, 'unknown');
    }

    return;
}

sub get_upload_info {
    my ($c, $frame) = @_;
    if (length $frame < 12) {
        stats_inc('bom_websocket_api.v_3.document_upload_error', {tags => ['source:' . $c->stash('source_type')]});
        return;
    }

    my ($call_type, $upload_id, $chunk_size, $data) = unpack "N3a*", $frame;
    my $upload_info = $c->stash->{document_upload}->{$upload_id};
    unless ($upload_info) {
        stats_inc('bom_websocket_api.v_3.document_upload_error', {tags => ['source:' . $c->stash('source_type')]});
        return;
    }

    die "Unknown call type"           if $call_type != $upload_info->{call_type};
    die "Maximum chunk size exceeded" if $chunk_size > MAX_CHUNK_SIZE;
    die "Incorrect chunk size"        if $chunk_size != length $data;

    return {
        chunk_size => $chunk_size,
        data       => $data,
        %{$upload_info},
    };
}

sub send_upload_failure {
    my ($c, $upload_info, $reason) = @_;

    clean_up_on_finish($c, $upload_info);

    $upload_info //= {
        echo_req    => {},
        req_id      => '1',
        passthrough => {}};

    $c->call_rpc({
            method      => 'document_upload',
            call_params => {
                token => $c->stash->{token},
            },
            args => {
                req_id      => $upload_info->{req_id},
                passthrough => $upload_info->{passthrough},
                reason      => $reason,
                status      => 'failure',
            },
            response => sub {
                my (undef, $api_response, $req_storage) = @_;

                replace_echo_req($upload_info, $req_storage);

                return create_error($upload_info, $api_response, $req_storage);
            },
        });

    return;
}

sub send_upload_successful {
    my ($c, $upload_info, $status, $checksum) = @_;

    clean_up_on_finish($c, $upload_info);

    my $upload_finished = {
        size      => $upload_info->{received_bytes},
        call_type => $upload_info->{call_type},
        checksum  => $checksum,
        status    => $status,
    };

    $c->call_rpc({
            method      => 'document_upload',
            call_params => {
                token => $c->stash->{token},
            },
            args => {
                req_id      => $upload_info->{req_id},
                passthrough => $upload_info->{passthrough},
                file_id     => $upload_info->{file_id},
                page_type   => $upload_info->{page_type},
                %{$upload_finished},
            },
            response => sub {
                my (undef, $api_response, $req_storage) = @_;
                replace_echo_req($upload_info, $req_storage);

                return create_error($upload_info, $api_response, $req_storage) if exists($api_response->{error});

                my $call_params = create_call_params($upload_info);

                return {
                    %{$call_params},
                    document_upload => {
                        %{$upload_finished},
                        upload_id => $upload_info->{upload_id},
                    }};
            },
        });

    return;
}

sub upload_chunk {
    my ($c, $upload_info) = @_;

    return if last_chunk_received($c, $upload_info);

    my $upload_id = $upload_info->{upload_id};
    my $data      = $upload_info->{data};
    my $stash     = $c->stash->{document_upload};

    my $new_received_bytes = $stash->{$upload_id}->{received_bytes} + length $data;

    return send_upload_failure($c, $upload_info, 'size_mismatch') if $new_received_bytes > $upload_info->{file_size};

    $stash->{$upload_id}->{md5}->add($data);
    $stash->{$upload_id}->{received_bytes} = $new_received_bytes;

    return resolve_with_received_chunk($c, $upload_info->{pending_futures}, $data);
}

sub create_error {
    my ($upload_info, $rpc_response, $req_storage) = @_;
    replace_echo_req($upload_info, $req_storage);
    return {%{create_call_params($upload_info)}, error => $rpc_response->{error}};
}

sub create_call_params {
    my $params = shift;

    return {
        msg_type    => 'document_upload',
        req_id      => $params->{req_id} || 0,
        passthrough => $params->{passthrough} || {},
        echo_req    => $params->{echo_req} || $params,
    };
}

sub create_response {
    my ($args, $payload) = @_;

    return {
        %{create_call_params($args)},
        document_upload => $payload,
    };
}

sub replace_echo_req {
    my ($upload_info, $req_storage) = @_;

    $req_storage->{args} = $upload_info->{echo_req};

    return;
}

sub generate_upload_id {
    my $stash = shift;
    return $stash->{last_upload_id} = exists $stash->{last_upload_id} ? ($stash->{last_upload_id} + 1) % (1 << 32) : 1;
}

sub clean_up_on_finish {
    my ($c, $upload_info) = @_;

    return unless $upload_info;

    $_->cancel for @{$upload_info->{pending_futures}}, $upload_info->{put_future};

    my $s3 = $upload_info->{s3};
    $c->loop->remove($s3) if grep { $_ == $s3 } $c->loop->notifiers;

    my $upload_id           = $upload_info->{upload_id};
    my $stash               = $c->stash->{document_upload};
    my $stashed_upload_info = $stash->{$upload_id};

    return unless $stashed_upload_info;

    delete $stashed_upload_info->{pending_futures};
    delete $stashed_upload_info->{put_future};
    delete $stashed_upload_info->{s3};
    delete $stash->{$upload_id};

    return;
}

sub wait_for_chunks_and_upload_to_s3 {
    my ($c, $upload_info) = @_;
    my $s3 = create_s3_instance($c, $upload_info);

    my $pending_futures = $upload_info->{pending_futures};

    return $upload_info->{put_future} = $s3->put_object(
        key          => $upload_info->{file_name},
        value        => sub { wait_for_chunk($c, $pending_futures) },
        value_length => $upload_info->{file_size},
    )->on_fail(sub { send_upload_failure($c, $upload_info, 'unknown') });
}

sub create_s3_instance {
    my ($c, $upload_info) = @_;

    my $s3 = Net::Async::Webservice::S3->new(
        %{Binary::WebSocketAPI::Hooks::get_doc_auth_s3_conf($c)},
        max_retries   => 1,
        stall_timeout => UPLOAD_STALL_TIMEOUT,
    );

    $c->loop->add($s3);

    $upload_info->{s3} = $s3;

    return $s3;
}

sub last_chunk_received {
    my ($c, $upload_info) = @_;

    return 0 if $upload_info->{chunk_size} != 0;

    my $checksum = $upload_info->{md5}->hexdigest;
    if ($checksum ne $upload_info->{expected_checksum}) {
        send_upload_failure($c, $upload_info, 'checksum_mismatch');
        return 1;
    }

    return Future->wait_any($upload_info->{put_future}, $c->loop->timeout_future(after => UPLOAD_TIMEOUT))->on_done(
        sub {
            my $etag = shift;
            $etag =~ s/"//g;
            return send_upload_successful($c, $upload_info, 'success', $checksum) if $checksum eq $etag;
            warn 'S3 etag does not match the checksum, this indicates a bug in the upload process';
            send_upload_failure($c, $upload_info, 'unknown');
        }
        )->on_fail(
        sub {
            send_upload_failure($c, $upload_info, 'unknown');
        })->retain;
}

sub wait_for_chunk {
    my ($c, $pending_futures) = @_;

    my $upload_future = get_oldest_pending_future($c, $pending_futures, 1);

    return $upload_future->on_ready(sub { shift @$pending_futures });
}

sub resolve_with_received_chunk {
    my ($c, $pending_futures, $received_chunk) = @_;

    my $upload_future = get_oldest_pending_future($c, $pending_futures);

    return $upload_future->done($received_chunk);
}

sub get_oldest_pending_future {
    my ($c, $pending_futures, $include_ready_futures) = @_;

    my $first_pending_future = first { not $_->is_ready unless $include_ready_futures } @$pending_futures;

    my $pending_future = $first_pending_future || $c->loop->new_future;

    push @$pending_futures, $pending_future unless $first_pending_future;

    return $pending_future;
}

1;
