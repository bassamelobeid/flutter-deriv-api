package Binary::WebSocketAPI::v3::Wrapper::Authenticate;

use strict;
use warnings;

use Digest::SHA1;

sub uploader {
    my $upload_id = shift;
    return sub {
        my ($params, $data) = @_;

        $params->{sha1}->add($data);
        $params->{size} = $params->{size} + length $data;

        open(my $fh, '>>', "/tmp/documents/$upload_id") or die 'Cannot open the file /tmp/documents/$upload_id';
        print $fh $data;
        close $fh;
    }
}

sub send_response {
    my ($c, $params) = @_;

    return sub {
        my $payload = shift;
        my $resp = {
            req_id => $params->{req_id},
            passthrough => $params->{passthrough} || {},
            msg_type => $params->{msg_type},
        };
        for my $key (keys %{ $payload }) {
            $resp->{$key} = $payload->{$key}; 
        }

        $c->send({
                json => $resp,
            })
    }
}


my $last_upload_id = 0;

sub generate_upload_id {
    return $last_upload_id < 2**31 - 1 ? ++$last_upload_id : ($last_upload_id = 1);
}

sub document_upload {
    my ($c, $rpc_response) = @_;

    my $args = $req_storage->{args};

	my $params = {
		upload_id => generate_upload_id(),
		call_type => 1,
		req_id => $args->{req_id},
		passthrough => $args->{passthrough},
		msg_type => 'upload_documents',
		uploader => uploader(10),
		sha1 => Digest::SHA1->new,
		size => 0,
	};

	$params->{send_response} = send_response($c, $params);

	$stash->{document_uploads}->{$params->{upload_id}} = $params;

	$params->{send_response}->({
			upload_documents => {
				file => {
					upload_id => $params->{upload_id},
					call_type => $params->{call_type},
				}
			}
		})

}

1;
