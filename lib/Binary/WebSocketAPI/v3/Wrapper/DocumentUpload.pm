package Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;

use strict;
use warnings;

use Try::Tiny;
use Digest::SHA1;

use constant MAX_FILE_SIZE => 3 * 2**20;    # 3 MB

my $fake_path = '/tmp/db/clientIDscans/';

sub add_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args = $req_storage->{origin_args};

    return create_error($args, $rpc_response) if $rpc_response->{error};

    my $current_stash = $c->stash('document_upload') || {};
    my $upload_id     = generate_upload_id();
    my $call_params   = create_call_params($args);
    my $stash         = {
        %{$current_stash},
        $upload_id => {
            %{$call_params},
            file_id        => $rpc_response->{file_id},
            file_name      => $rpc_response->{file_name},
            call_type      => $rpc_response->{call_type},
            sha1           => Digest::SHA1->new,
            received_bytes => 0,
            document_path  => $fake_path,
        },
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

    my $upload_info;

    try {
        $upload_info = get_upload_info($c, $frame);

        return upload($c, $upload_info) if $upload_info->{chunk_size} != 0;

        send_upload_successful($c, $upload_info, 'success');
    }
    catch {
        warn "UploadError: $_";
        send_upload_failure($c, $upload_info, 'unknown');
    };

    return;
}

sub get_upload_info {
    my ($c, $frame) = @_;

    die 'Invalid frame' unless length $frame >= 12;

    my ($call_type, $upload_id, $chunk_size, $data) = unpack "N3a*", $frame;

    die "Unknown upload request" unless my $stash       = $c->stash('document_upload');
    die "Unknown upload id"      unless my $upload_info = $stash->{$upload_id};
    die "Unknown call type"      unless $call_type == $upload_info->{call_type};
    die "Incorrect data size"    unless $chunk_size == length $data;

    return {
        chunk_size => $chunk_size,
        data       => $data,
        upload_id  => $upload_id,
        %{$upload_info},
    };
}

sub send_upload_failure {
    my ($c, $upload_info, $reason) = @_;

    delete_upload_info($c, $upload_info);

    $upload_info = {
        req_id      => '1',
        passthrough => {}} if not defined $upload_info;

    $c->call_rpc({
            method      => 'document_upload',
            call_params => {
                token => $c->stash('token'),
            },
            args => {
                req_id      => $upload_info->{req_id},
                passthrough => $upload_info->{passthrough},
                reason      => $reason,
                status      => 'failure',
            },
        });

    return;
}

sub send_upload_successful {
    my ($c, $upload_info, $status) = @_;

    delete_upload_info($c, $upload_info);

    my $upload_finished = {
        size      => $upload_info->{received_bytes},
        checksum  => $upload_info->{sha1}->hexdigest,
        call_type => $upload_info->{call_type},
        status    => $status,
    };

    $c->call_rpc({
            method      => 'document_upload',
            call_params => {
                token => $c->stash('token'),
            },
            args => {
                req_id        => $upload_info->{req_id},
                passthrough   => $upload_info->{passthrough},
                file_id       => $upload_info->{file_id},
                document_path => $upload_info->{document_path},
                %{$upload_finished},
            },
            response => sub {
                my $api_response = $_[1];

                return create_error($upload_info, $api_response) if exists($api_response->{error});

                return {
                    %{$api_response},
                    req_id          => $upload_info->{req_id},
                    passthrough     => $upload_info->{passthrough},
                    document_upload => {
                        %{$upload_finished},
                        upload_id => $upload_info->{upload_id},
                    }};
            }
        });

    return;
}

sub upload {
    my ($c, $upload_info) = @_;
    my $upload_id = $upload_info->{upload_id};
    my $data      = $upload_info->{data};
    my $file_name = $upload_info->{file_name};
    my $stash     = $c->stash('document_upload');

    my $new_received_bytes = $stash->{$upload_id}->{received_bytes} + length $data;
    return send_upload_failure($c, $upload_info, 'max_size') if $new_received_bytes > MAX_FILE_SIZE;

    $stash->{$upload_id}->{sha1}->add($data);
    $stash->{$upload_id}->{received_bytes} = $new_received_bytes;

    # TODO: Stream through a cloud storage

    if (not -d $fake_path) {
        system("mkdir -p $fake_path");
    }

    return send_upload_failure($c, $upload_info) unless open my $fh, '>>:raw', "$fake_path/$file_name";

    print $fh $data;
    close $fh;
    return;
}

sub create_error {
    my ($call_params, $rpc_response) = @_;
    return {
        %{create_call_params($call_params)},
        error => exists($rpc_response->{error})
        ? $rpc_response->{error}
        : {
            code    => 'UploadError',
            message => 'Sorry, we cannot process your upload request',
        },
    };
}

sub create_call_params {
    my $params = shift;

    return {
        msg_type    => 'document_upload',
        req_id      => $params->{req_id} || 0,
        passthrough => $params->{passthrough} || {},
    };
}

sub create_response {
    my ($args, $payload) = @_;

    return {
        %{create_call_params($args)},
        document_upload => $payload,
    };
}

my $last_upload_id = 0;

sub generate_upload_id {
    return $last_upload_id = ($last_upload_id + 1) % (1 << 32);
}

sub remove_echo_req {
    my (undef, $req_storage, undef) = @_;

    my $args = $req_storage->{args};

    return unless exists($req_storage->{msg_type}) and $req_storage->{msg_type} eq 'document_upload' and exists($args->{status});

    $req_storage->{args} = {
        req_id      => $args->{req_id},
        passthrough => $args->{passthrough},
    };

    return;
}

sub delete_upload_info {
    my ($c, $upload_info) = @_;
    return unless defined $upload_info;
    my $stash = $c->stash('document_upload');
    delete $stash->{$upload_info->{upload_id}};
    return;
}

1;
