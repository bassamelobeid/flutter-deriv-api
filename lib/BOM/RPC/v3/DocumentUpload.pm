package BOM::RPC::v3::DocumentUpload;

use strict;
use warnings;
use BOM::Platform::Context qw (localize);

sub upload {
    my $params = shift;
    my ($client, $upload_id) = @{$params}{qw/client upload_id document_type document_id document_format expiration_date/};
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UploadDenied',
            message_to_client => localize("Virtual accounts don't require uploads.")}) if $client->is_virtual;
    
}

1;
