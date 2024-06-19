use strict;
use warnings;
use BOM::User::Script::DeleteOctetStreamType;

=head1 NAME

delete_octet_stream_type

=head1 DESCRIPTION

This script is to delete files from s3 that contain octet-stream type.  

=cut

BOM::User::Script::DeleteOctetStreamType::remove_client_authentication_docs_from_S3({noisy => 1});
