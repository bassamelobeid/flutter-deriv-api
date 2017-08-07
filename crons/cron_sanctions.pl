#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use Path::Tiny;

use Brands;
use Client::Account;
use BOM::Database::ClientDB;
use BOM::Platform::Client::Sanctions;
use BOM::Platform::Email qw(send_email);

=head2

 This scripts:
 - tries to update sanctions cached file
 - runs check for all clients agains sanctioned list, but only if list has changed since last run

=cut

my $file_flag    = '/tmp/last_cron_sanctions_check_run';
my $reports_path = shift or die "Provide path for storing files as an argument";
my @brokers      = qw/CR MF MLT MX/;

my $brand = Brands->new(name => 'binary');

my $last_run = (stat $file_flag)[9] // 0;
$BOM::Platform::Client::Sanctions::sanctions->update_data();
{ open my $fh, '>', $file_flag; close $fh };
exit if $last_run > $BOM::Platform::Client::Sanctions::sanctions->last_updated();

my $matched = {map { $_ => get_matched_clients_by_broker($_) } @brokers};
do_report($matched);

sub do_report {
    my $matched = shift;
    my $headers =
        'List Name,List Updated,Database,LoginID,First Name,Last Name,Email,Phone,Gender,DateOfBirth,DateJoined,Residence,Citizen,Status,Reason';
    my $r = '';
    foreach my $k (sort keys %$matched) {
        $r .= make_client_csv_line($_) . "\n" for sort { $a->[0]->loginid cmp $b->[0]->loginid } @{$matched->{$k}};
    }
    print $r;

    my $csv_file = path($reports_path . '/sanctions-run-' . Date::Utility->new()->date . '.csv');
    $csv_file->spew_utf8($headers . "\n");
    $csv_file->spew_utf8($r . "\n");

    send_email({
        from       => $brand->emails('support'),
        to         => $brand->emails('compliance'),
        cc         => 'sysadmin@binary.com',
        subject    => 'Sanction list checked',
        message    => ["Here is a list of clients against sanctions:\n$r"],
        attachment => $csv_file->canonpath,
    });
    return;
}

sub make_client_csv_line {
    my ($c, $list) = @{+shift};
    my @fields = (
        $list,
        Date::Utility->new($BOM::Platform::Client::Sanctions::sanctions->last_updated($list))->date,
        (map { $c->$_ // '' } qw(broker loginid first_name last_name email phone gender date_of_birth date_joined residence citizen)),
        (map { $_->status_code, $_->reason } ($c->client_status->[0])),    #use only last status
    );
    return join(',', @fields);
}

sub get_matched_clients_by_broker {
    my $broker = shift;
    my @matched;
    my $clients = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        }
        )->db->dbh->selectcol_arrayref(
        q{
        SELECT
            loginid
        FROM
            betonmarkets.client
        WHERE
            loginid ~
        }, undef, '^' . $broker . '\d'
        );

    foreach my $c (@$clients) {
        my $client = Client::Account->new({loginid => $c});
        my $list = BOM::Platform::Client::Sanctions->new({
                client => $client,
                brand  => $brand,
                type   => 'C',
            })->check();
        push @matched, [$client, $list] if $list;
    }
    return \@matched;
}

