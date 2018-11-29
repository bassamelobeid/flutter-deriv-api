#!/etc/rmg/bin/perl

use strict;
use warnings;
binmode STDOUT, ':encoding(UTF-8)';

use Date::Utility;
use Data::Validate::Sanctions;
use Path::Tiny;
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
my @brokers = qw/CR MF MLT MX/;

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

    my $r = '';
    for my $broker (@brokers) {
        $log->infof('Starting %s at %s', $broker, scalar localtime);
        my $result = get_matched_clients_info_by_broker($broker);
        $r .= $result // '';
        $log->infof('Finished %s at %s', $broker, scalar localtime);
    }

    $log->info($r);

    my $headers =
        'Matched name,List Name,List Updated,Database,LoginID,First Name,Last Name,Email,Phone,Gender,Date Of Birth,Date Joined,Residence,Citizen,Matched Reason';

    my $csv_file = path($reports_path . '/sanctions-run-' . Date::Utility->new()->date . '.csv');
    $csv_file->append_utf8($headers . "\n");
    $csv_file->append_utf8($r . "\n");

    my $brand = Brands->new(name => 'binary');

    $log->infof('Wrote CSV file %s', $csv_file);

    send_email({
        from       => $brand->emails('support'),
        to         => join(',', $brand->emails('compliance'), 'sysadmin@binary.com'),
        subject    => 'Sanction list checked',
        message    => ["Here is a list of clients against sanctions:\n$r"],
        attachment => $csv_file->canonpath,
    });
    return;
}

sub get_matched_clients_info_by_broker {

    my $broker = shift;

    my $dbic = BOM::Database::ClientDB->new({
            broker_code  => $broker,
            db_operation => 'write',
        })->db->dbic;

    my $output = '';
    my $csv    = Text::CSV->new({
        eol        => "\n",
        quote_char => undef
    });

    my $updates = $dbic->run(
        fixup => sub {
            my $update_sanctions_check =
                $_->prepare(q{UPDATE betonmarkets.sanctions_check SET result=?,tstmp=now(),type='C' WHERE client_loginid = ?});

            my $sth = $_->prepare(
                q{
                   SELECT broker_code, loginid, first_name, last_name, email, phone, gender, date_of_birth, date_joined, residence, citizen
                   FROM betonmarkets.client
                   WHERE loginid ~ ('^' || ? || '\\d')
                   ORDER BY loginid
                 }
            );
            $sth->execute($broker);
            my $client;
            while ($client = $sth->fetchrow_hashref()) {

                my $sinfo = $sanctions->get_sanctioned_info($client->{first_name}, $client->{last_name}, $client->{date_of_birth});
                $update_sanctions_check->execute($sinfo->{matched} ? $sinfo->{list} : '0', $client->{loginid});

                if ($sinfo->{matched}) {
                    my @fields = (
                        $sinfo->{name},
                        $sinfo->{list},
                        $listdate{$sinfo->{list}} //= Date::Utility->new($sanctions->last_updated($sinfo->{list}))->date,
                        (
                            map { $client->{$_} // '' }
                                qw(broker_code loginid first_name last_name email phone gender date_of_birth date_joined residence citizen)
                        ),
                        $sinfo->{reason},
                    );
                    $csv->combine(@fields);
                    $output .= $csv->string();
                }
            }
        });

    return $output;
}
