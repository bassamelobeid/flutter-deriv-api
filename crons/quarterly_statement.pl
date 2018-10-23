#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Getopt::Long qw( GetOptions );
Getopt::Long::Configure qw( gnu_getopt );

use POSIX;
use Template;
use Try::Tiny;
use Path::Tiny;
use Date::Utility;
use Email::Address::UseXS;
use Email::Stuffer;
use JSON::MaybeXS;

use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Event::Emitter;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'debug';

my $send_emails  = 0;
my $show_summary = 0;
my $show_clients = 0;

# parse command line options
GetOptions(
    'send-emails|s'   => \$send_emails,
    'print-summary|i' => \$show_summary,
    'print-clients|c' => \$show_clients,
) or die 'Usage $0 [--send-emails] [--print-summary] [--print-clients] <quarter>';

# Decide which quarter we're running for, and the start/end dates
my $quarter = shift(@ARGV) || do {
    my $date = Date::Utility->new->_minus_months(1);
    $date->year . 'Q' . $date->quarter_of_year;
};
die 'invalid quarter format - expected something like 2017Q3' unless $quarter =~ /^\d{4}Q[1-4]$/;

my $months_in_quarter = 3;
my $start             = Date::Utility->new($quarter =~ s{Q([1-4])}{'-' . (1 + $months_in_quarter * ($1 - 1)) . '-01'}er);
my $end               = $start->plus_time_interval($months_in_quarter . 'mo');

$log->infof('Generating client quarterly statement emails for %s (%s - %s)', $quarter, $start->iso8601, $end->iso8601);

my $tt = Template->new(ABSOLUTE => 1);

# This is hardcoded to work on European clients only, since it's required for regulatory reasons there.
my @brokers = qw/MF/;
for my $broker (@brokers) {

    # Iterate through all clients - we have few enough that we can pull the entire list into memory
    # (even if we increase userbase by 100x or more). We don't filter out by status at this point:
    # the statement generation may take a few seconds for each client, and there's a chance
    # that the status will change during the run.
    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbic;

    my $clients = $dbic->run(
        fixup => sub {
            $_->selectcol_arrayref(q{SELECT loginid FROM betonmarkets.client});
        });
    $log->infof('Found a total of %d clients in %s', 0 + @$clients, $broker);

    my $params = {
        source        => 1,
        date_from     => $start->epoch(),
        date_to       => $end->epoch(),
        email_subject => 'Quarterly Statement',
    };

    for my $loginid (@$clients) {

        try {

            $log->infof('Instantiating %s', $loginid);

            my $client = BOM::User::Client->new({
                loginid      => $loginid,
                db_operation => 'replica'
            });

            # Skip any inactive clients
            return $log->infof('Skipping %s due to unwelcome status', $loginid) if $client->status->unwelcome;
            return $log->infof('Skipping %s due to disabled status',  $loginid) if $client->status->disabled;

            if ($send_emails) {
                $params->{loginid} = $client->loginid;
                BOM::Platform::Event::Emitter::emit('email_statement', $params);
            }

            $log->infof("Job has been pushed to the statement queue for client: %s and sending email for: %s", $loginid, $client->email)
                if $show_clients;
        }
        catch {
            $log->errorf('Failed to process quarterly statement for client [%s] - %s', $loginid, $_);
        }
    }

}
