#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Path::Tiny;
use Syntax::Keyword::Try;

use BOM::Platform::ProveID;
use BOM::Config::Runtime;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Client;
use Date::Utility;
use Time::Duration::Concise::Localize;
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);

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
        } catch {
            stats_event('ProveID Failed', 'ProveID Failed, an email should have been sent', {alert_type => 'warning'});
            warn "ProveID failed, $@";
        }
    }
}

##########################
# Helper functions       #
##########################

sub get_db_for_broker {
    return BOM::Database::ClientDB->new({
            broker_code => shift,
            operation   => 'backoffice_replica',
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

    my $clients = [grep { $_ =~ /$broker/ } map { $_->{client_loginid} } @$result];
    stats_inc("proveid.cron.request.number_of_clients", scalar @$clients);
    return $clients;
}

sub get_client {
    my $loginid = shift;

    try {
        return BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'backoffice_replica'
        });
    } catch {
        die "Error: can't identify client $loginid: $@";
    }
}
