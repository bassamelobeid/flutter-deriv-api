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
use feature "state";


BOM::Platform::Sysinit::init();
PrintContentType();

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

my $currency = $client->currency;

my $statement = client_statement_for_backoffice({
    client   => $client,
    before   => Date::Utility->new({datetime => $enddate})->plus_time_interval('1d')->date,
    after    => $startdate,
    currency => $currency,
    max_number_of_lines => 10000,
});

foreach my $transaction (@{$statement->{transactions}}) {
    if (defined $transaction->{financial_market_bet_id}) {
        my $key = $transaction->{date}->datetime;
        my $info = BOM::View::Controller::Bet::get_info($transaction, $currency);
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id} . " description: " . $info->{longcode};
        $key_value .= " buy_price: " . $transaction->{buy_price} if $transaction->{buy_price};
        $key_value .= " sell_price: " . $transaction->{sell_price} if $transaction->{sell_price};
        push @audit_entries, { timestring => $key, description => $key_value, color => 'gray' };
    } else {
        my $key = $transaction->{date}->datetime;
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id} . " description: " . $transaction->{payment_remark} . " amount: $currency " . $transaction->{amount};
        push @audit_entries, { timestring => $key, description => $key_value, color => 'red' };
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
foreach my $table (qw(client client_status client_promo_code client_authentication_method client_authentication_document self_exclusion) ) {
    $prefix = ($table eq 'client')? '':'client_';
    $u_db = $dbh->selectall_hashref("SELECT * FROM audit.$table WHERE ".$prefix."loginid='$loginid' and stamp between '$startdate'::TIMESTAMP and '$enddate'::TIMESTAMP order by stamp", 'stamp');

    my $old;
    foreach my $stamp (sort keys %{$u_db}) {
        my $new = $u_db->{$stamp};
        my $diffs;
        if (not $old) {
            $old = $new;
        }
        if ($new->{operation} eq 'INSERT') {
            my $desc=$new->{stamp} . " [$table audit table] " . join(' ', map {$new->{$_}} qw(operation client_addr)).'<ul>';
            foreach my $key (keys %{$new}) {
                $desc .= "<li> $key is <b>" . ($new->{$key} || '') . '</b> </li> ';
            }
            push @audit_entries, { timestring => $new->{stamp}, description =>  "$desc</ul>", color => 'purple' };
            $old = $new;
        }
        foreach my $key (sort keys %{$u_db->{$stamp}}) {
            $new->{secret_answer} = BOM::Platform::Client::Utility::decrypt_secret_answer($new->{secret_answer}) if $key eq 'secret_answer';
            if ($key eq 'client_addr') {
                    $old->{client_addr} = revers_ip($old->{client_addr});
            }
            $new->{$key} = '' if not $new->{$key};
            if ($key !~ /(stamp|operation|pg_userid|client_addr|client_port)/) {
                if ($old and $old->{$key} ne $new->{$key}) {
                    $diffs->{$key} = 1;
                }
            }
            
        }
        if ($diffs) {

            my $desc=$old->{stamp} . " [$table audit table] " . join(' ', map {$old->{$_}} qw(operation client_addr)).'<ul>';

            foreach my $key (keys %{$diffs}) {
                $desc .= "<li> $key ". ' ' . 'change from <b>'. $old->{$key} . '</b> to <b>' . $new->{$key} . '</b> </li> ';
            }
            push @audit_entries, { timestring => $old->{stamp}, description =>  "$desc</ul>", color => 'blue' };
        }
        $old = $new;

    }
}

$u_db = $dbh->selectall_hashref("SELECT * FROM audit.login_history WHERE client_loginid='$loginid' and stamp between '$startdate'::TIMESTAMP and '$enddate'::TIMESTAMP order by stamp", 'stamp');

foreach my $stamp (sort keys %{$u_db}) {
    $u_db->{$stamp}->{client_addr} = revers_ip($u_db->{$stamp}->{client_addr});
    my $desc=$u_db->{$stamp}->{stamp} . " [login_history audit table] " . join(' ', map {$u_db->{$stamp}->{$_}} qw( client_addr  ));
    delete $u_db->{$stamp}->{login_action};
    delete $u_db->{$stamp}->{operation};
    delete $u_db->{$stamp}->{id};
    delete $u_db->{$stamp}->{client_loginid};
    delete $u_db->{$stamp}->{pg_userid};
    delete $u_db->{$stamp}->{client_port};
    delete $u_db->{$stamp}->{client_addr};
    delete $u_db->{$stamp}->{stamp};
    delete $u_db->{$stamp}->{login_date};
    foreach my $key (keys %{$u_db->{$stamp}}) {
        $desc .= "$key  <b>". $u_db->{$stamp}->{$key} . '</b> ';
    }
    my $color = ($u_db->{$stamp}->{login_successful})? 'green' : 'orange';
    push @audit_entries, { timestring => $stamp, description =>  "$desc", color => $color };
}

print "<div style='background-color:yellow'>$loginid</div>";
print "<div style='background-color:white'>";
my $old;
foreach (sort { Date::Utility->new($a->{timestring})->epoch <=> Date::Utility->new($b->{timestring})->epoch } @audit_entries ) {
    print '<hr>' if (substr($_->{timestring},0,10) ne substr($old->{timestring},0,10) );
    print "<div style='font-size:11px;color:".$_->{color}."'>" . $_->{description} . "</div>";
    $old = $_;
}
print "</div>";


sub revers_ip {
    my $client_ip = shift;
    state $r;
    if ($r->{$client_ip}) {
        return $r->{$client_ip};
    }
    my $ip = $client_ip;
    $ip =~ s/\/32//g;
    my $reverse = `/usr/bin/host $ip`;
    $reverse =~ /\s([^\s]+)\.$/;
    if ($1) {
        $r->{$client_ip} = $1;
    }  else {
        $r->{$client_ip} = $ip;
    }
    return $r->{$client_ip};
}
