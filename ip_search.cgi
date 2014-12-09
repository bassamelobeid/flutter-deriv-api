#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Persistence::DAO::Report::ClientAccountReport;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();

PrintContentType();

my $ip = request()->param('ip');
BrokerPresentation("IP SEARCH FOR $ip");
BOM::Platform::Auth0::can_access(['CS']);
my $broker = request()->broker->code;

if ($ip !~ /^\d+\.\d+\.\d+\.\d+$/) {
    print "Invalid IP $ip";
    code_exit_BO();
}

Bar("Searching for LoginIDs corresponding to $ip");

# Search IP address from clients loginhistory file
my $last_login_age = request()->param('lastndays');

my @login_history_result = BOM::Platform::Persistence::DAO::Report::ClientAccountReport::get_logins_by_ip_and_login_age({
    ip             => $ip,
    broker         => $broker,
    last_login_age => $last_login_age,
});

if (scalar @login_history_result == 0) {
    print "No logins found for IP address [$ip] in the last [" . request()->param('lastndays') . "] days";
} else {

    foreach my $login_history (@login_history_result) {
        my $loginid           = $login_history->{'loginid'};
        my $login_date        = $login_history->{'login_date'};
        my $login_environment = $login_history->{'login_environment'};
        my $login_ip;

        if ($login_environment =~ /^IP=(.*)\s/) {
            $login_ip = $1;
        } elsif ($login_environment =~ /^(\d+\.\d+\.\d+\.\d+\s)/) {
            $login_ip = $1;
        } else {
            $login_ip = $login_environment;
        }

        print '<br>' . $loginid . "  date= " . $login_date . " ip= $ip";

    }
}

code_exit_BO();
