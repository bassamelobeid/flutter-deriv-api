#!/etc/rmg/bin/perl

use strict;
use warnings;
binmode STDOUT, ':encoding(UTF-8)';

use Date::Utility;
use Data::Validate::Sanctions;
use Path::Tiny qw(path);
use Getopt::Long;
use Text::CSV;

use Brands;
use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Platform::Email qw(send_email);

use Log::Any qw($log);
use Log::Any::Adapter;

=head2

 This script:
 - tries to update sanctions cached file
 - runs check for all clients against sanctioned list, but only if list has changed since last run

=cut

GetOptions(
    'v|verbose' => \(my $verbose = 0),
    'f|force'   => \(my $force   = 0),
) or die "Invalid argument\n";

Log::Any::Adapter->import(qw(Stdout), log_level => $verbose ? 'info' : 'warning');
my $reports_path = shift or die "Provide path for storing files as an argument";

# The broker codes are ordered for two reasons:
# 1. Regulated broker codes (EU) has a higher priority
# 2. The regulated broker codes have a smaller number of clients, in comparison to CR
# Thus, it would be better to send the emails one at a time, with regulated ones first
my @brokers = qw/MF MX MLT CR/;

my $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Config::sanction_file);

my $file_flag = path('/tmp/last_cron_sanctions_check_run');
my $last_run = $file_flag->exists ? $file_flag->stat->mtime : 0;
$sanctions->update_data();

$file_flag->spew("Created by $0 PID $$");
if (($last_run > $sanctions->last_updated()) && !$force) {
    $log->infof('Exiting because sanctions appear up to date (file=%s)', $file_flag);
    exit 0;
}

my %listdate;

do_report();

sub do_report {

    my $result;
    my $brand = Brands->new(name => 'binary');

    my $today_date = Date::Utility::today()->date;

    my @headers =
        (
        'Matched name,List Name,List Updated,DOB (From list),DOB (Client),Database,LoginID,First Name,Last Name,Gender,Date Joined,Residence,Citizen,Matched Reason'
        );

    my $csv = Text::CSV->new({
        eol        => "\n",
        quote_char => undef
    });

    my $csv_rows;

    for my $broker (@brokers) {

        $log->infof('Starting %s at %s', $broker, scalar localtime);

        $csv_rows = get_matched_clients_info_by_broker($broker);

        $log->infof('Finished %s at %s', $broker, scalar localtime);

        # CSV creation starts here
        my $filename = path($reports_path . '/' . $broker . '_daily_sanctions_report_' . $today_date . '.csv');
        my $file     = path($filename)->openw_utf8;

        $csv->print($file, \@headers);
        $csv->print($file, $_) for @$csv_rows;
        # CSV creation ends here

        $log->infof('Wrote CSV file %s', $filename);

        close $file;

        send_email({
            from       => $brand->emails('support'),
            to         => join(',', $brand->emails('compliance'), 'sysadmin@binary.com'),
            subject    => 'Sanction list for ' . $broker . ' at ' . $today_date,
            attachment => $filename->canonpath,
        });
    }

    return undef;
}

sub get_matched_clients_info_by_broker {

    my $broker = shift;

    my $dbic = BOM::Database::ClientDB->new({
            broker_code  => $broker,
            db_operation => 'write',
        })->db->dbic;

    my @csv_rows;
    my $csv_row;
    my $client;
    my $client_matched;
    my $sinfo;

    $dbic->run(
        fixup => sub {

            my $update_sanctions_check =
                $_->prepare(q{UPDATE betonmarkets.sanctions_check SET result=?,tstmp=now(),type='C' WHERE client_loginid = ?});

            my $query_filter = $_->prepare(
                q{
                SELECT broker_code, loginid, first_name, last_name, gender, date_of_birth, date_joined, residence, citizen
                FROM betonmarkets.client
                WHERE loginid ~ ('^' || ? || '\\d')
                ORDER BY loginid
            }
            );

            $query_filter->execute($broker);

            while ($client = $query_filter->fetchrow_hashref()) {

                $sinfo = $sanctions->get_sanctioned_info($client->{first_name}, $client->{last_name}, $client->{date_of_birth});
                $client_matched = $sinfo->{matched} ? $sinfo->{list} : '';

                $update_sanctions_check->execute($client_matched, $client->{loginid});

                next unless $sinfo->{matched};

                $csv_row = [
                    $sinfo->{name},
                    $sinfo->{list},
                    $listdate{$sinfo->{list}} //= Date::Utility->new($sanctions->last_updated($sinfo->{list}))->date,
                    $sinfo->{matched_dob},
                    (map { $client->{$_} // '' } qw(date_of_birth broker_code loginid first_name last_name gender date_joined residence citizen)),
                    $sinfo->{reason}];

                push @csv_rows, $csv_row;
            }
        });

    return \@csv_rows;
}
