#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use JSON;
use Data::Dumper;
use Date::Utility;
use DateTime;

use f_brokerincludeall;
use BOM::Platform::Context;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::View::Controller::Bet;

BOM::Platform::Sysinit::init();
PrintContentType();
BrokerPresentation("SHOW CLIENT COMBINED TRACE");

my $loginid    = uc(request()->param('loginid'));
my $startdate  = request()->param('startdate');
my $enddate    = request()->param('enddate');

# get client complete transaction statements
my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid});
if (not $client) {
    print "Error : wrong loginID ($loginid) could not get client instance";
    code_exit_BO();
}

my @audit_entries;
my %wd_query = (
    login_date => {ge_le => [DateTime->from_epoch(epoch => Date::Utility->new({datetime => $startdate})->epoch), DateTime->from_epoch(epoch => Date::Utility->new({datetime => $enddate})->epoch)]},
);

my $logins = $client->find_login_history(
    query   => [%wd_query],
    sort_by => 'login_date',
    limit   => 200,
);

foreach my $login (@$logins) {
    my $date        = $login->login_date->strftime('%F %T');
    my $status      = $login->login_successful ? 'ok' : 'failed';
    push @audit_entries, {timestring => $date, description => $date . " logged in: " . $status . " " . $login->login_environment};
}

my $currency = $client->currency;

my $statement = client_statement_for_backoffice({
    client   => $client,
    before   => Date::Utility->new({datetime => $enddate})->plus_time_interval('1d')->date,
    after    => $startdate,
    currency => $currency,
});

foreach my $transaction (@{$statement->{transactions}}) {
    if (defined $transaction->{financial_market_bet_id}) {
        my $key = $transaction->{date}->datetime;
        my $info = BOM::View::Controller::Bet::get_info($transaction, $currency);
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id} . " description: " . $info->{longcode};
        $key_value .= " buy_price: " . $transaction->{buy_price} if $transaction->{buy_price};
        $key_value .= " sell_price: " . $transaction->{sell_price} if $transaction->{sell_price};
        push @audit_entries, { timestring => $key, description => $key_value };
    }
}


my $dbh = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
        operation   => 'backoffice_replica',
    })->db->dbh or die "[$0] cannot create connection";
$dbh->{AutoCommit} = 0;
$dbh->{RaiseError} = 1;

my $u_db;
my $prefix;
foreach my $table (qw(client client_status client_promo_code client_authentication_method client_authentication_document) ) {
    $prefix = ($table eq 'client')? '':'client_';
    $u_db = $dbh->selectall_hashref("SELECT * FROM audit.$table WHERE ".$prefix."loginid='$loginid' and stamp between '$startdate'::TIMESTAMP and '$enddate'::TIMESTAMP order by stamp", 'stamp');

    my $old;
    foreach my $stamp (keys %{$u_db}) {
        my $new = $u_db->{$stamp};
        my $diffs;
        foreach my $key (keys %{$u_db->{$stamp}}) {
            if ($key !~ /(stamp|operation|pg_userid|client_addr|client_port)/) {
                if ($old->{$key} ne $new->{$key}) {
                    $diffs->{$key} = 1;
                } 
            }
        }
        if ($diffs) { 
            my $desc= '<ul>';
            foreach my $key (keys %{$diffs}) {
                $desc .= "<li> $key ". ' ' . 'change from <b>'. $old->{$key} . '</b> to <b>' . $new->{$key} . '</b> </li> ';
            }
            push @audit_entries, { timestring => $stamp, description => $u_db->{$stamp}->{stamp} .' ' . "$desc</ul>" };
        }
        $old = $new;

    }
}


print "<table style='background-color:white'>";
foreach (sort { Date::Utility->new($a->{timestring})->epoch <=> Date::Utility->new($b->{timestring})->epoch } @audit_entries ) {
    print "<tr><td>" . $_->{description} . "</td></tr>";
}
print "</table>";
