#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use Data::Validate::Sanctions;
use Path::Tiny;

use Brands;
use Client::Account;
use BOM::Database::ClientDB;
use BOM::Platform::Config;
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
my $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Platform::Config::sanction_file);

my $last_run = (stat $file_flag)[9] // 0;
#$sanctions->update_data();
#{ open my $fh, '>', $file_flag; close $fh };
#exit if $last_run > $sanctions->last_updated();

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
        to         => join(',', $brand->emails('compliance'), 'sysadmin@binary.com'),
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
        Date::Utility->new($sanctions->last_updated($list))->date,
        (map { $c->$_ // '' } qw(broker loginid first_name last_name email phone gender date_of_birth date_joined residence citizen)),
        (map { $_->status_code, $_->reason } ($c->client_status->[0])),    #use only last status
    );
    return join(',', @fields);
}

sub get_matched_clients_by_broker {
    my $broker = shift;
    my @matched;
    my $dbh = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbh;
    my $clients = $dbh->selectcol_arrayref(
        q{
        SELECT
            loginid
        FROM
            betonmarkets.client
        WHERE
            loginid ~ ('^' || ? || '\\d')
        }, undef, $broker
    );
    #XXX: can we rely on rows? New rows are added on client's registration
    # WHERE condition we need only for QA
    $dbh->do("UPDATE betonmarkets.sanctions_check SET result='0',type='C',tstmp=? WHERE client_loginid ~ ('^' || ? || '\\d')",
        undef, Date::Utility->new->datetime, $broker);
    foreach my $c (@$clients) {
        my $client = Client::Account->new({loginid => $c});
        my $list = $sanctions->is_sanctioned($client->first_name, $client->last_name);
        push @matched, [$client, $list] if $list;
    }
    return [] unless @matched;
    my $values = join ",", ('(?,?)') x scalar @matched;
    $dbh->do(
        qq{
            WITH input(result, client_loginid)
                AS(VALUES $values)
            UPDATE betonmarkets.sanctions_check s
            SET result=input.result
            FROM input
            WHERE s.client_loginid=input.client_loginid
            }, undef, map { $_->[1] => $_->[0]->loginid } @matched
    ) or warn $DBI::errstr;

    return \@matched;
}

