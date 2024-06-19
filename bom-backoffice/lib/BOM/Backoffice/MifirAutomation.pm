package BOM::Backoffice::MifirAutomation;
use strict;
use warnings;
use BOM::Config::Redis;
use Text::CSV;
use Date::Utility;
use BOM::Config;
use BOM::Platform::Email qw(send_email);

# Retrieves the list of failed IDs from Redis set.
# Returns: Array reference containing the failed IDs.
sub get_failed_ids {
    return BOM::Config::Redis::redis_replicated_write()->smembers("mifir_id_update_failed") // [];
}

# Writes the list of failed IDs to a CSV file.
# Parameters:
#   - $failed_ids: Array reference containing the failed IDs.
sub write_failed_ids_to_csv {
    my $failed_ids = shift;
    my $csv        = Text::CSV->new({binary => 1, eol => $/});
    open my $fh, ">", "/tmp/failed_ids.csv" or die "/tmp/failed_ids.csv: $!";
    $csv->print($fh, [$_]) for @$failed_ids;
    close $fh;
}

# Runs the MIFIR failed email check.
# Retrieves the list of failed IDs,
# creates a CSV file with the IDs, and sends an email with the CSV file as an attachment.
sub run {
    my $failed_ids = get_failed_ids();
    my $today_date = Date::Utility::today()->date;
    my $brand      = BOM::Config->brand();

    write_failed_ids_to_csv($failed_ids);
    if (scalar $failed_ids->@*) {
        send_email({
            from       => $brand->emails('support'),
            to         => $brand->emails('compliance_regs'),
            subject    => 'MIFIR ID update failed at ' . $today_date,
            attachment => ["/tmp/failed_ids.csv"],
        });
        BOM::Config::Redis::redis_replicated_write()->del("mifir_id_update_failed");
    }

}

1;
