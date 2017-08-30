package Binary::WebSocketAPI::v3::Wrapper::Authenticate;

use strict;
use warnings;

use Digest::SHA1;
use BOM::Platform::Context qw(localize);

sub add_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args   = $req_storage->{origin_args};

    return create_error($args) if $rpc_response->{error};

    my $current_stash = $c->stash('document_upload');
    my $upload_id = generate_upload_id();

    my $stash = {
        %{ $current_stash },
        $upload_id => {
            %{ create_call_params($args) },
            file_name      => $rpc_response->{file_name},
            call_type      => $rpc_response->{call_type},
            sha1           => Digest::SHA1->new,
            received_bytes => 0,
            document_path  => '/hostname/filehash',
        },
    };

    $c->stash(document_upload => $stash);

    return create_response($args, {
        upload_id => $upload_id,
        call_type => $stash->{call_type},
    });
}

sub document_upload {
    my ($c, $frame) = @_;

    my $upload_info;

    try {
        $upload_info = get_upload_info($c, $frame);
        
        return upload($upload_info) if $upload_info->{chunk_size} != 0;

        upload_finished($c, $upload_info);
    } catch {
        $c->send(create_error($upload_info));    
    };
}

sub get_upload_info {
    my ($c, $frame) = @_;

    die 'Invalid frame' unless length $frame >= 12;

    my ($call_type, $upload_id, $chunk_size, $data) = unpack "N3a*", $frame;

    die "Unknown upload request" unless my $stash = $c->stash('document_upload');
    die "Unknown upload id"      unless my $upload_info == $stash->{upload_id};
    die "Unknown call type"      unless $call_type == $upload_info->{call_type};
    die "Incorrect data size"    unless $chunk_size == length $data;

    return {
        chunk_size => $chunk_size,
        data       => $data,
        upload_id  => $upload_id,
        %{ $upload_info },
    };
}

sub upload_finished {
    my ($c, $upload_info) = @_;    

    $c->call_rpc({
        method      => 'document_upload',
        call_params => {
            token => $c->stash('token'),
        },
        args => {
            file_name     => $upload_info->{file_name},
            size          => $upload_info->{received_bytes},
            checksum      => $upload_info->{sha1}->hexdigest,
            call_type     => $upload_info->{call_type},
            document_path => $upload_info->{document_path},
            status        => 'success',
        },
        response => sub {
            my $api_response = $_[1];

            return create_error($upload_info) unless exists($api_response->{document_upload});

            return {
                %{$api_response},
                req_id          => $upload_info->{req_id},
                passthrough     => $upload_info->{passthrough},
                document_upload => {
                    %{ $api_response->{document_upload} },
                    upload_id => $upload_info->{upload_id},
                }};
        }
    });
};

sub upload {
    my $upload_info = shift;
    my $data = $upload_info->{data};
    my $new_upload_info = { %{ $upload_info } }; 

    $new_upload_info->{sha1}->add($data);
    $new_upload_info->{received_bytes} = $new_upload_info->{received_bytes} + length $data;

    # TODO: Stream through a cloud storage

    return $new_upload_info;
}

sub create_error {
    return {
        %{ create_call_params(shift) },
        error => {
            code    => 'UploadError',
            message => localize('Sorry, we cannot process your upload request'),
        },
    };
};

sub create_call_params {
    my $params = shift;

    return {
        msg_type    => 'document_upload',
        req_id      => $params->{req_id} || 0,
        passthrough => $params->{passthrough} || {},
    };
};

sub create_response {
    my ($args, $payload) = @_;

    return {
        %{ create_call_params($args) },
        document_upload => $payload,
    };
};

my $last_upload_id = 0;
sub generate_upload_id {
    return $last_upload_id = ($last_upload_id + 1) % (1 << 32);
}

1;
