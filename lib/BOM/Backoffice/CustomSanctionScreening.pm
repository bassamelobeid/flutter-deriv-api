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
    my $csv             = Text::CSV->new({binary => 1}) or die "Cannot use CSV: " . Text::CSV->error_diag();
    my @data;
    my $header = $csv->getline($csv_file_handle);
    $csv->column_names(@$header);
    while (my $row = $csv->getline_hr($csv_file_handle)) {
        push @data, $row;
    }
    return \@data;
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
    } catch ($error) {
        if ($redis) {
            $log->warn("Error occurred while saving data to Redis: $error");
        } else {
            $log->warn("Error occurred while getting Redis instance: $error");
        }
    };

    return;
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
1;
