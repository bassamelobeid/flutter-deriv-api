#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $loginid = request()->param('loginID');
BrokerPresentation("$loginid CLIENT LOGIN HISTORY");
BOM::Platform::Auth0::can_access(['CS']);

my @loginIDarray = split(/\s/, uc($loginid));

foreach my $loginID (@loginIDarray) {
    if ($loginID =~ /^\D+\d+$/) {
        Bar("$loginID Login History");

        my $login_history_result = get_client_login_history_arrayref($loginID);

        print '<pre>';
        if (not $login_history_result) {
            print '<p>There is no login history record for client [' . $loginID . ']</p>';
        }

        foreach my $login_history (@{$login_history_result}) {
            my $login_date        = $login_history->{'login_date'}->datetime_ddmmmyy_hhmmss_TZ;
            my $login_status      = $login_history->{'login_status'};
            my $login_environment = $login_history->{'login_environment'};

            print $login_date. ' ' . $login_status . ' ' . $login_environment;
        }
        print '</pre>';
    }
}

code_exit_BO();

