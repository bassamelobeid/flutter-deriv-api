#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom-backoffice/lib";
}

use Email::Address::UseXS;
use Email::Stuffer;
use BOM::Platform::Context qw (request);
use Template;

use BOM::Backoffice::Sysinit ();
use BOM::Database::DataMapper::CollectorReporting;
use BOM::User;
use BOM::User::Client;

BOM::Backoffice::Sysinit::init();

if ($ENV{REQUEST_METHOD}) {
    die 'REQUEST_METHOD[' . $ENV{REQUEST_METHOD} . '] exists!?';
}

my $check_date    = Date::Utility->new(time - 86400)->date;
my $support_email = request()->brand->emails('support');
my $template      = Template->new(ABSOLUTE => 1);

# connect to collector for getting data
my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
    broker_code => 'FOG',
    operation   => 'collector'
});

my $client_dup_list = $report_mapper->check_clients_duplication(Date::Utility->new($check_date)->truncate_to_day);

my @client_data;
my %dup_unique;
foreach my $client_hash (@{$client_dup_list}) {

    # skip if client_hash is completely empty
    next if (not $client_hash->{first_name} and not $client_hash->{last_name} and not $client_hash->{date_of_birth});

    my $loginid = $client_hash->{new_loginid};
    my $reason  = $client_hash->{reason};

    # this ensures we only show the first account, which is the oldest one
    next if exists $dup_unique{$loginid . $reason};
    $dup_unique{$_ . $reason} = 1 for @{$client_hash->{loginids}}, $loginid;

    my $client = BOM::User::Client::get_instance({loginid => $loginid});

    my $siblings = {map { $_->loginid => 1 } $client->user->clients};

    my @duplicate_clients = grep { !($_ eq $loginid || exists $siblings->{$_}) } @{$client_hash->{loginids}};

    next unless @duplicate_clients;

    push @client_data,
        {
        loginid            => $loginid,
        reason             => $reason,
        first_name         => $client_hash->{first_name},
        last_name          => $client_hash->{last_name},
        phone              => $client->phone,
        duplicated_loginid => join(', ', @duplicate_clients)};

}

if (@{$client_dup_list}) {
    my $template_data = {
        clients_data => \@client_data,
        check_date   => $check_date,
    };
    $template->process('/home/git/regentmarkets/bom-backoffice/templates/email/duplicated_clients.html.tt', $template_data, \my $html)
        or die 'Template error: ' . $template->error;
    Email::Stuffer->from($support_email)->to($support_email)->subject("Duplicate clients found on $check_date")->html_body($html)->send_or_die;
}

=head1 NAME

cron_check_duplicate_new_client.pl

=head1 DESCRIPTION

This is a CRON script to check whether the account that is opened yesterday has the same first name and last name
with old accounts. This cron will send the result to cs team to check if duplicate account detected.

=cut
