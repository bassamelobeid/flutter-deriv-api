package BOM::Backoffice::FileUpload;

use strict;
use warnings;
use HTML::Entities;
use Text::Trim;

use constant DOCUMENT_SIZE_LIMIT_IN_BYTES => 10_000_000;    # 10 MB

=head2 is_post_request($cgi)

Checks if the current request is a POST request.

=over 4

=item * C<$cgi> - The CGI object representing the current request.

=back

Returns: A boolean value indicating whether the request is a POST request.
=cut

sub is_post_request {
    my ($cgi) = @_;
    return $cgi->request_method() eq 'POST';
}

=head2 get_batch_file($file)

Retrieves the batch file from the request.

=over 4

=item * C<$file> - The file object representing the uploaded file, or an array reference containing the file object.

=back

Returns: The trimmed batch file name.

=cut

sub get_batch_file {
    my ($file) = @_;
    my $batch_file = ref $file eq 'ARRAY' ? trim($file->[0]) : trim($file);
    return $batch_file;
}

=head2 validate_file($file)

Validates the uploaded file.

=over 4

=item * C<$file> - The file object representing the uploaded file.

=back

Returns: An error message if the file is not a CSV file or if it exceeds the maximum allowed size. Otherwise, returns an empty string.
=cut

sub validate_file {
    my ($file) = @_;
    return "ERROR: $file: only csv files allowed\n" unless $file =~ /(csv)$/i;
    return "ERROR: " . encode_entities($file) . " is too large." if $ENV{CONTENT_LENGTH} > (DOCUMENT_SIZE_LIMIT_IN_BYTES);
    return;
}

1;
