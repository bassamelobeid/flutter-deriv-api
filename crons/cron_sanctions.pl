package main;
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom-backoffice/lib";
}

use BOM::Backoffice::Sysinit ();
use BOM::Database::DataMapper::CollectorReporting;
use Client::Account;
use BOM::Database::ClientDB;
use BOM::Platform::Client::Sanctions;
use Brands;
use Data::Dumper;

=head2

 This scripts runs check for all clients agains sanctioned list, but only if list has changed since last run

=cut

my $file_flag = '/tmp/last_cron_sanctions_check_run';
$BOM::Platform::Client::Sanctions::sanctions->update_data();

my $last_run = (stat $file_flag)[9] // 0;
{ open my $fh, '>', $file_flag; close $fh };
exit if $last_run > $BOM::Platform::Client::Sanctions::sanctions->last_updated();

my $brokers = ['CR', 'MF', 'MLT', 'MX'];
my $matched;
$matched->{$_} = do_broker($_) for @$brokers;
my $headers = 'List Name,Database,LoginID,First Name,Last Name,Email,Phone,Gender,DateOfBirth,DateJoined,Residence,Citizen,Status,Reason\n';
my $r       = '';
foreach my $k (keys %$matched) {
    $r .= map_client_data($_) . "\n" for @{$matched->{$k}};
}
print $r;

sub map_client_data {
    my ($c, $list) = @{+shift};
    my $r = '';
    $r .= $list . ',';
    $r .= $c->$_ . ',' foreach qw(broker loginid first_name last_name email phone gender date_of_birth date_joined residence citizen);
    $r .= $_->status_code . ',' . $_->reason . ',' for ($c->client_status->[0]);    #use only last status
    return $r;
}

sub do_broker {
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
    }
        );

    foreach my $c (@$clients) {
        my $client = Client::Account->new({loginid => $c});
        my $list;
        push @matched,
            [$client, $list]
            if $list = BOM::Platform::Client::Sanctions->new({
                client     => $client,
                brand      => Brands->new(name => 'binary'),
                skip_email => 1,
            })->check();
    }
    return \@matched;
}

sub check_last_update {

}
