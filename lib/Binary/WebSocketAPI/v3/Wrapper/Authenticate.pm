package Binary::WebSocketAPI::v3::Wrapper::Authenticate;

use strict;
use warnings;

use Digest::SHA1;

sub uploader {
    my $stash = shift;
    return sub {
        my $data = shift;

        $stash->{sha1}->add($data);
        $stash->{received_bytes} = $stash->{received_bytes} + length $data;

        # TODO: Stream through a cloud storage
    };
}

my $last_upload_id = 0;

sub generate_upload_id {
    return ($last_upload_id = ($last_upload_id + 1) % (1 << 32));
}

sub add_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args   = $req_storage->{origin_args};
    my $error  = $rpc_response->{error};
    my $params = {
        msg_type    => 'document_upload',
        req_id      => $args->{req_id},
        passthrough => $args->{passthrough} || {},
    };

    return {
        %{$params},
        error => {
            code    => $error->{code},
            message => $error->{message_to_client},
        },
    } if $error;

    my $stash = {
        %{$params},
        file_name      => $rpc_response->{file_name},
        call_type      => $rpc_response->{call_type},
        upload_id      => generate_upload_id(),
        sha1           => Digest::SHA1->new,
        received_bytes => 0,
        document_path  => 's3://hostname/filehash',
    };

    $stash->{uploader} = uploader($stash);

    $c->stash(document_upload => $stash);

    return {
        %{$params},
        document_upload => {
            upload_id => $stash->{upload_id},
            call_type => $stash->{call_type},
        }};
}

1;
