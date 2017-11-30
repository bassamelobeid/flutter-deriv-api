package Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;

use strict;
use warnings;

use Try::Tiny;
use Digest::SHA;
use Net::Async::Webservice::S3;
use Future;
use JSON::MaybeXS qw/decode_json/;

use Binary::WebSocketAPI::Hooks;

use constant MAX_CHUNK_SIZE       => 2**17;    #100KB
use constant UPLOAD_TIMEOUT       => 120;
use constant UPLOAD_STALL_TIMEOUT => 60;

sub add_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args = $req_storage->{origin_args};

    return create_error($args, $rpc_response) if $rpc_response->{error};

    my $current_stash = $c->stash->{document_upload} || {};
    my $upload_id     = generate_upload_id($current_stash);
    my $call_params   = create_call_params($args);

    my $upload_info = {
        %{$call_params},
        file_id         => $rpc_response->{file_id},
        call_type       => $rpc_response->{call_type},
        file_name       => $rpc_response->{file_name},
        file_size       => $args->{file_size},
        sha1            => Digest::SHA->new,
        received_bytes  => 0,
        pending_futures => [],
        upload_id       => $upload_id,
    };

    create_s3_instance($c, $upload_info);

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

    # Ignore valid json frames;
    return if eval { decode_json($frame) };

    my $upload_info;

    try {
        $upload_info = get_upload_info($c, $frame);

        upload_chunk($c, $upload_info);
    }
    catch {
        warn "UploadError (app_id: " . $c->app_id . "): $_";
        send_upload_failure($c, $upload_info, 'unknown');
    };

    return;
}

sub get_upload_info {
    my ($c, $frame) = @_;

    die 'Invalid frame' if length $frame < 12;

    my ($call_type, $upload_id, $chunk_size, $data) = unpack "N3a*", $frame;

    my $upload_info = $c->stash->{document_upload}->{$upload_id} or die "Unknown upload request";

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

                return create_error($upload_info, $api_response);
            },
        });

    return;
}

sub send_upload_successful {
    my ($c, $upload_info, $status) = @_;

    clean_up_on_finish($c, $upload_info);

    my $upload_finished = {
        size      => $upload_info->{received_bytes},
        checksum  => $upload_info->{sha1}->hexdigest,
        call_type => $upload_info->{call_type},
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
                %{$upload_finished},
            },
            response => sub {
                my (undef, $api_response, $req_storage) = @_;

                replace_echo_req($upload_info, $req_storage);

                return create_error($upload_info, $api_response) if exists($api_response->{error});

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

    $stash->{$upload_id}->{sha1}->add($data);
    $stash->{$upload_id}->{received_bytes} = $new_received_bytes;

    return add_upload_future($c, $upload_info->{pending_futures}, $data);
}

sub create_error {
    my ($call_params, $rpc_response) = @_;
    return {%{create_call_params($call_params)}, error => $rpc_response->{error}};
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
    my ($c, $upload_info_copy) = @_;

    return unless $upload_info_copy and exists $upload_info_copy->{upload_id};

    my $upload_id   = $upload_info_copy->{upload_id};
    my $stash       = $c->stash->{document_upload};
    my $upload_info = $stash->{$upload_id};

    return unless $upload_info;

    $_->cancel for @{$upload_info->{pending_futures}}, $upload_info->{put_future};
    $c->loop->remove($upload_info->{s3});

    delete $upload_info->{pending_futures};
    delete $upload_info->{put_future};
    delete $upload_info->{s3};
    delete $stash->{$upload_id};

    return;
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

    my $pending_futures = $upload_info->{pending_futures};

    $upload_info->{put_future} = $s3->put_object(
        key          => $upload_info->{file_name},
        value        => sub { add_upload_future($c, $pending_futures) },
        value_length => $upload_info->{file_size},
    )->on_fail(sub { send_upload_failure($c, $upload_info, 'unknown') });

    return;
}

sub last_chunk_received {
    my ($c, $upload_info) = @_;

    return if $upload_info->{chunk_size} != 0;

    return Future->wait_any($upload_info->{put_future}, $c->loop->timeout_future(after => UPLOAD_TIMEOUT))->on_done(
        sub {
            send_upload_successful($c, $upload_info, 'success');
        }
        )->on_fail(
        sub {
            send_upload_failure($c, $upload_info, 'unknown');
        });
}

sub add_upload_future {
    my ($c, $pending_futures, $received_chunk) = @_;

    my ($current_pending_future) = grep { not($received_chunk and $_->is_ready) } @{$pending_futures};

    my $upload_future = $current_pending_future || $c->loop->new_future;

    push @{$pending_futures}, $upload_future if not $current_pending_future;

    if ($received_chunk) {
        $upload_future->done($received_chunk);
    } else {
        $upload_future->on_ready(sub { shift @{$pending_futures} });
    }

    return $upload_future;
}

1;
