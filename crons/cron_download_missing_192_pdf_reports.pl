#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Path::Tiny;
use Try::Tiny;

use BOM::Platform::ProveID;
use BOM::Config::Runtime;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Client;
use Date::Utility;
use Time::Duration::Concise::Localize;

use constant HOURS_TO_QUERY => 4;    # This cron runs every hour, but we will pick up clients with `proveid_pending` status set 4 hours in the past.

my $accounts_dir = BOM::Config::Runtime->instance->app_config->system->directory->db . "/f_accounts";
my $search_option = 'ProveID_KYC';    # At the time of writing this script, this is the only search option we have

for my $broker (qw(MX)) {
    my $pending_loginids = find_loginids_with_pending_experian($broker);
    for my $loginid (@$pending_loginids) {

        try {
            my $client = get_client($loginid);

            BOM::Platform::Client::IDAuthentication->new(
                client => $client,
            )->proveid;
        }
        catch {
            warn "ProveID failed, $_";
        };
    }
}

##########################
# Helper functions       #
##########################

sub get_db_for_broker {
    return BOM::Database::ClientDB->new({
            broker_code => shift,
            operation   => 'replica',
        })->db;
}

sub find_loginids_with_pending_experian {
    my $broker = shift;
    my $dbic   = get_db_for_broker($broker)->dbic;
    my $time   = Date::Utility->new()->minus_time_interval(Time::Duration::Concise::Localize->new('interval' => HOURS_TO_QUERY . 'h'))
        ->datetime_yyyymmdd_hhmmss;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', {Slice => {}}, $time) });
SELECT client_loginid FROM betonmarkets.client_status
WHERE status_code = 'proveid_pending' AND last_modified_date >= ?;
SQL

    return [grep { $_ =~ /$broker/ } map { $_->{client_loginid} } @$result];
}

sub get_client {
    my $loginid = shift;

    return try {
        BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        });
    }
    catch {
        die "Error: can't identify client $loginid: $_";
    };
}
