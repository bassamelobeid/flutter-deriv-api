package Binary::WebSocketAPI::v3::Wrapper::Authenticate;

use strict;
use warnings;

use Digest::SHA1;

sub uploader {
    my $upload_id = shift;
    return sub {
        my ($params, $data) = @_;

        $params->{sha1}->add($data);
        $params->{received_bytes} = $params->{received_bytes} + length $data;

        # TODO: Stream through a cloud storage
        }
}

my $last_upload_id = 0;

sub generate_upload_id {
    return $last_upload_id < 2**31 - 1 ? ++$last_upload_id : ($last_upload_id = 1);
}


sub save_upload_info {
    my ($c, $rpc_response, $req_storage) = @_;

    my $file_id = $rpc_response->{file_id};
	my $upload_id = generate_upload_id();

    my $params = {
		file_id		   => $file_id,
        upload_id      => $upload_id,
        call_type      => $rpc_response->{call_type},
        uploader       => uploader($upload_id),
        sha1           => Digest::SHA1->new,
        received_bytes => 0,
        req_id         => $req_storage->{req_id},
        passthrough    => $req_storage->{passthrough},
    };

    $c->stash(document_uploads => $params);
}

1;
