package BOM::Backoffice::CustomSanctionScreening;

use strict;
use warnings;
use Text::CSV;
use BOM::Config::Redis;
use Date::Utility;
use Syntax::Keyword::Try;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(:v1);

use constant SANCTION_CSV_LIST => 'BO::SANCTION_CSV_LIST';

use constant {
    FIRST_NAME             => 'first_name',
    LAST_NAME              => 'last_name',
    DATE_OF_BIRTH          => 'date_of_birth',
    REQUIRED_HEADERS_COUNT => 3
};

=head2 read_custom_sanction_csv_file($cgi)

Reads a custom sanction CSV file and returns the data as an array reference.

=over 4

=item * C<$cgi> - The CGI object representing the current request.

=back

Returns: An array reference containing the data from the CSV file.
=cut

sub read_custom_sanction_csv_file {
    my ($cgi)           = @_;
    my $csv_file_handle = $cgi->upload('screening_csv_file');
    my $csv             = Text::CSV->new({binary => 1});
    my $headers         = $csv->getline($csv_file_handle);
    my $error_message   = validate_csv_headers($headers);
    if ($error_message) {
        return (undef, $error_message);
    }

    my @data;
    $csv->column_names(@$headers);
    while (my $row = $csv->getline_hr($csv_file_handle)) {
        push @data, $row;
    }
    return (\@data, undef);
}

=head2 save_custom_sanction_data_to_redis($data)

Saves the custom sanction data to Redis.

=over 4

=item * C<$data> - An array reference containing the custom sanction data.

=back

Returns: Nothing.

=cut

sub save_custom_sanction_data_to_redis {
    my ($data) = @_;

    my $redis;
    try {
        $redis = BOM::Config::Redis::redis_replicated_write();

        $redis->del(SANCTION_CSV_LIST);
        my $today_date     = Date::Utility::today()->date;
        my $data_with_date = {
            date_uploaded => $today_date,
            data          => $data
        };
        my $json_data = encode_json_utf8($data_with_date);
        $redis->set(SANCTION_CSV_LIST, $json_data);
        return 1;
    } catch ($error) {
        if ($redis) {
            $log->warn("Error occurred while saving data to Redis: $error");
        } else {
            $log->warn("Error occurred while getting Redis instance: $error");
        }
        return 0;
    };

}

=head2 retrieve_custom_sanction_data_from_redis()

Retrieves the custom sanction data from Redis.

Returns: A hash reference containing the custom sanction data and the date it was uploaded.
=cut

sub retrieve_custom_sanction_data_from_redis {
    my $redis     = BOM::Config::Redis::redis_replicated_read();
    my $json_data = $redis->get(SANCTION_CSV_LIST);
    return defined $json_data ? decode_json_utf8($json_data) : undef;
}

=head2 validate_csv_headers($headers)

Validate CSV headers.

This subroutine validates if the given headers array reference contains the required headers:
'first_name', 'last_name', and 'date_of_birth'.

=head3 Parameters

=over 4

=item * C<$headers> - Reference to an array containing CSV headers.

=back

=head3 Returns

=over 4

=item * If headers are valid, returns C<undef>.

=item * If headers are missing or incorrect, returns an error message string.

=back

=cut

sub validate_csv_headers {
    my ($headers) = @_;

    return "Missing headers: '" . FIRST_NAME . "', '" . LAST_NAME . "', '" . DATE_OF_BIRTH . "'"
        unless (defined $headers
        && @$headers >= REQUIRED_HEADERS_COUNT
        && $headers->[0] eq FIRST_NAME
        && $headers->[1] eq LAST_NAME
        && $headers->[2] eq DATE_OF_BIRTH);

    return;
}

1;
