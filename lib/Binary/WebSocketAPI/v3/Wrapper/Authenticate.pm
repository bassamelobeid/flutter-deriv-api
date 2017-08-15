package Binary::WebSocketAPI::v3::Wrapper::Authenticate;

use strict;
use warnings;

use Digest::SHA1;

sub uploader {
    my $params = shift;
    return sub {
        my $data = shift;

        $params->{sha1}->add($data);
        $params->{received_bytes} = $params->{received_bytes} + length $data;

        # TODO: Stream through a cloud storage
    };
}

my $last_upload_id = 0;

sub generate_upload_id {
    return $last_upload_id = ($last_upload_id + 1) % 1 << 32;
}


sub save_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;

    my $params = {
	file_id        => $rpc_response->{file_id},
        call_type      => $rpc_response->{call_type},
	upload_id      => generate_upload_id(),
        sha1           => Digest::SHA1->new,
	received_bytes => 0,
	req_id         => $req_storage->{req_id},
        passthrough    => $req_storage->{passthrough},
    };

    $params->{uploader} = uploader($params);
    
    $c->stash(document_uploads => $params);
}

1;
