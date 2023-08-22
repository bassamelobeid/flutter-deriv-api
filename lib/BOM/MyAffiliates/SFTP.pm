package BOM::MyAffiliates::SFTP;

=head1 NAME

BOM::MyAffiliates::SFTP;

=head1 DESCRIPTION

SFTP wrapper for using it daily cron jobs for lookback, registrations and other similar files

=cut

use strict;
use warnings;
use Net::SFTP::Foreign;
use Syntax::Keyword::Try;
use Log::Any qw($log);
use YAML::XS qw(LoadFile);

use constant CONFIG          => '/etc/rmg/third_party.yml';
use constant RETRY_LIMIT     => 5;
use constant WAIT_IN_SECONDS => 30;
use constant FTP_PATH        => '/myaffiliates/bom/data/';

my $temp_config = LoadFile(CONFIG)->{myaffiliates};
my %config      = %$temp_config;

=head2 send_csv_via_sftp

function for sending csv file to myaffiliate SFTP server in order to sync data between backoffice and Myaffiliate

=cut

sub send_csv_via_sftp {
    my ($local_csv_filepath, $folder, $brand) = @_;

    my $csv_file_name = (split '/', $local_csv_filepath)[-1];

    if ($brand eq "binary") {
        $config{sftp_path} = FTP_PATH . 'bom/';
    } else {
        $config{sftp_path} = FTP_PATH . 'deriv/';
    }

    my $succeed = 0;
    for (my $try = 1; $try < RETRY_LIMIT && !$succeed; $try++) {
        try {
            my $sftp = Net::SFTP::Foreign->new(
                $config{sftp_host},
                user                       => $config{sftp_username},
                password                   => $config{sftp_password},
                port                       => $config{sftp_port},
                asks_for_username_at_login => 'auto'
            ) or die "Cannot connect to: " . $config{sftp_host} . " $@";

            $log->infof('Connected to: %s', $config{sftp_host});

            my $remote_filepath = $config{sftp_path} . $folder . '/' . $csv_file_name;

            $log->infof('Uploading file: %s to %s', $local_csv_filepath, $remote_filepath);

            $sftp->put($local_csv_filepath, $remote_filepath);

            if ($sftp->error) {
                $log->errorf('Can\'t upload %s to %s: [%s]', $local_csv_filepath, $remote_filepath, $sftp->error);
            } else {
                $log->infof('File %s uploaded successfully to %s', $local_csv_filepath, $remote_filepath);
                $succeed = 1;
            }

            $sftp->disconnect;

        } catch ($e) {
            sleep WAIT_IN_SECONDS;
            $log->errorf('Attempt to upload files failed: [%s]', $e);
        }
    }
    return $succeed;
}

1;
