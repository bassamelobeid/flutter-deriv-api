#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use Data::Validate::Sanctions;
use Path::Tiny;
use Parallel::ForkManager;

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
my $verbose      = 0;
my $childs       = 2;

my $brand = Brands->new(name => 'binary');
my $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Platform::Config::sanction_file);

my $last_run = (stat $file_flag)[9] // 0;
$sanctions->update_data();
{ open my $fh, '>', $file_flag; close $fh };
exit if $last_run > $sanctions->last_updated();

do_report();

sub do_report {
    my $pm = Parallel::ForkManager->new($childs);
    my $r  = '';
    $pm->run_on_finish(
        sub {
            my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_structure_reference) = @_;
            if (defined($data_structure_reference)) {    # children are not forced to send anything
                $r .= $$data_structure_reference;
            }
        });
    for (@brokers) {
        $pm->start and next;
        warn time, " $_ starting" if $verbose;
        my $result = get_matched_clients_info_by_broker($_);
        warn time, " $_ finished" if $verbose;
        $pm->finish(0, \$result);
    }
    $pm->wait_all_children;

    print $r if $verbose;

    my $headers =
        'Matched name,List Name,List Updated,Database,LoginID,First Name,Last Name,Email,Phone,Gender,DateOfBirth,DateJoined,Residence,Citizen,Status,Reason';

    my $csv_file = path($reports_path . '/sanctions-run-' . Date::Utility->new()->date . '.csv');
    $csv_file->append_utf8($headers . "\n");
    $csv_file->append_utf8($r . "\n");

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
    my ($c, $list, $matched_name) = @{+shift};
    my @fields = (
        $matched_name,
        $list,
        Date::Utility->new($sanctions->last_updated($list))->date,
        (map { $c->$_ // '' } qw(broker loginid first_name last_name email phone gender date_of_birth date_joined residence citizen)),
        (map { $_ ? ($_->status_code, $_->reason) : ('', '') } ($c->client_status->[0])),    #use only last status
    );
    return join(',', @fields);
}

sub get_matched_clients_info_by_broker {
    my $broker = shift;
    my @matched;
    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbic;
    my $clients = $dbic->run(
        fixup => sub {
            $_->selectcol_arrayref(
                q{
        SELECT
            loginid
        FROM
            betonmarkets.client
        WHERE
            loginid ~ ('^' || ? || '\\d')
        }, undef, $broker
            );
        });
    #XXX: can we rely on rows? New rows are added on client's registration
    # WHERE condition we need only for QA
    $dbic->run(
        ping => sub {
            $_->do("UPDATE betonmarkets.sanctions_check SET result='0',type='C',tstmp=? WHERE client_loginid ~ ('^' || ? || '\\d')",
                undef, Date::Utility->new->datetime, $broker);
        });
    foreach my $c (@$clients) {
        my $client = Client::Account->new({
            loginid      => $c,
            db_operation => 'replica'
        });
        my $result = $sanctions->get_sanctioned_info($client->first_name, $client->last_name);
        push @matched, [$client, $result->{list}, $result->{name}] if $result->{matched};
    }
    return '' unless @matched;

    my $values = join ",", ('(?,?)') x scalar @matched;
    $dbic->run(
        ping => sub {
            $_->do(
                qq{
            WITH input(result, client_loginid)
                AS(VALUES $values)
            UPDATE betonmarkets.sanctions_check s
            SET result=input.result
            FROM input
            WHERE s.client_loginid=input.client_loginid
            }, undef, map { $_->[1] => $_->[0]->loginid } @matched
            );
        }) or warn $DBI::errstr;

    my $result = '';
    $result .= make_client_csv_line($_) . "\n" for sort { $a->[0]->loginid cmp $b->[0]->loginid } @matched;

    return $result;
}

