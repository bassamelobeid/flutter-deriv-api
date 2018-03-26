#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom-backoffice/lib";
}

use BOM::Backoffice::Sysinit ();
use BOM::Database::DataMapper::CollectorReporting;
use BOM::User;
use BOM::User::Client;

BOM::Backoffice::Sysinit::init();

if ($ENV{REQUEST_METHOD}) {
    die 'REQUEST_METHOD[' . $ENV{REQUEST_METHOD} . '] exists!?';
}

my $check_date = Date::Utility->new(time - 86400)->date;

#connect to collector for getting data
my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
    broker_code => 'FOG',
    operation   => 'collector'
});
my $client_dup_list = $report_mapper->check_clients_duplication(Date::Utility->new($check_date)->truncate_to_day);

# Duplicate new client found
my $note_header = qq{
=========================================================================================
The following client opened an account on $check_date but has the same name and date of birth as other clients.
=========================================================================================\n\n};

my $dup_unique;
foreach my $client_hash (@{$client_dup_list}) {
    # avoid sending multiple emails for same client with multiple duplicate loginids
    my $client_str = join(',', $client_hash->{first_name} // '', $client_hash->{last_name} // '', $client_hash->{date_of_birth} // '');
    next if (defined $dup_unique and exists $dup_unique->{$client_str});
    $dup_unique->{$client_str} = 1;

    my $loginid = $client_hash->{new_loginid};
    my $client  = BOM::User::Client::get_instance({loginid => $loginid});
    my $user    = BOM::User->new({email => $client->email});

    my $siblings = {map { $_->loginid => 1 } $user->clients};
    my @duplicate_clients = map {
        # SQL function returns an array, every element is loginid and client status, joined by /
        # Status can be an empty string
        my ($lid, $status) = split '/', $_, 2;
        $lid eq $loginid || exists $siblings->{$lid} ? ()
            : length $status ? "$lid(\u$status)"
            :                  $lid;
    } @{$client_hash->{loginids}};

    next unless @duplicate_clients;

    my $note_content = $note_header;
    $note_content .= $loginid . '(' . $client_hash->{first_name} . ' ' . $client_hash->{last_name} . ")\n";
    $note_content .= '   Duplicate login id: ' . join(', ', @duplicate_clients) . "\n\n";
    $client->add_note("Duplicate clients found for [$loginid] opened on $check_date", $note_content);
}

=head1 NAME

cron_check_duplicate_new_client.pl

=head1 DESCRIPTION

This is a CRON script to check whether the account that is opened yesterday has the same first name and last name
with old accounts. This cron will send the result to cs team to check if duplicate account detected.

=cut
