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
my @brokers = qw(MF MX MLT CR);

my $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Config::sanction_file);

my $file_flag = path('/tmp/last_cron_sanctions_check_run');
my $last_run = $file_flag->exists ? $file_flag->stat->mtime : 0;

my %listdate;

do_report();

sub do_report {

    my $result;
    my $brand = Brands->new(name => 'binary');

    my $today_date           = Date::Utility::today()->date;
    my $last_sanction_update = $sanctions->last_updated();
    if (($last_run > $last_sanction_update) && !$force) {
        my $last_date                 = Date::Utility->new()->datetime_ddmmmyy_hhmmss_TZ;
        my $last_sanction_update_date = Date::Utility->new($last_sanction_update)->datetime_ddmmmyy_hhmmss_TZ;
        send_email({
            from    => $brand->emails('support'),
            to      => join(',', $brand->emails('compliance'), 'sysadmin@binary.com'),
            subject => "No sanctions changes for $today_date",
            message => ["Last sanction list update : $last_sanction_update_date \n" . "Last sanction cron ran : $last_date"],
        });

        return undef;
    }

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

    $file_flag->spew_utf8("Created by $0 PID $$");

    return undef;
}

sub get_matched_clients_info_by_broker {
    my $broker = shift;

    my $dbic = BOM::Database::ClientDB->new({
            broker_code  => $broker,
            db_operation => 'write',
        })->db->dbic;

    my $get_clients_from_pagination = sub {
        my ($limit, $last_loginid) = @_;
        my $clients = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref(q{select * from betonmarkets.get_active_clients(?, ?, ?)}, {Slice => {}}, $broker, $limit, $last_loginid);
            });
        return $clients;
    };

    my $update_sanctions = sub {
        my ($loginid, $matched) = @_;
        $dbic->run(
            fixup => sub {
                my $sth = $_->prepare(q{select betonmarkets.update_client_sanctions_check(?, ?)});
                $sth->execute($matched, $loginid);
            });
    };

    my @csv_rows;
    my $sinfo;

    my $last_loginid;
    my $limit = 1000;

    while (my @clients = $get_clients_from_pagination->($limit, $last_loginid)->@*) {
        for my $client (@clients) {
            $sinfo = $sanctions->get_sanctioned_info($client->{first_name}, $client->{last_name}, $client->{date_of_birth});
            $update_sanctions->($client->{loginid}, $sinfo->{matched} ? $sinfo->{list} : '');
            next unless $sinfo->{matched};

            push
                @csv_rows,
                [
                $sinfo->{name},
                $sinfo->{list},
                $listdate{$sinfo->{list}} //= Date::Utility->new($sanctions->last_updated($sinfo->{list}))->date,
                $sinfo->{matched_dob},
                (map { $client->{$_} // '' } qw(date_of_birth broker_code loginid first_name last_name gender date_joined residence citizen)),
                $sinfo->{reason}];

        }

        $last_loginid = $clients[-1]->{loginid};
    }

    return \@csv_rows;
}
