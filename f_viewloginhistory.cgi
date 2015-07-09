#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use BOM::Platform::Client;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BOM::Backoffice::Auth0::can_access(['CS']);
my ($loginid, $email_list);

if ($email_list = request()->param('email')) {
    BrokerPresentation("USER LOGIN HISTORY");

    my @emails = split(/\s+/, lc($email_list));
    foreach my $email (@emails) {
        Bar("$email Login History");

        print '<pre>';
        my $user = BOM::Platform::User->new({ email => $email });
        if (not $user) {
            print "<p>User [$email] not exist</p>";
        } else {
            my $login_history_result = $user->find_login_history(
                sort_by => 'history_date desc',
                limit   => 100
            );
            if (not $login_history_result) {
                print "<p>No login history for user [$email]</p>";
            }

            foreach my $login_history (@{$login_history_result}) {
                my $date        = $login_history->history_date;
                my $action      = $login_history->action;
                my $status      = $login_history->successful ? 'ok' : 'failed';
                my $environment = $login_history->environment;

                print "$date $action $status $environment\n";
            }
        }
        print '</pre>';
    }
} elsif ($loginid = request()->param('loginID')) {
    BrokerPresentation("$loginid CLIENT LOGIN HISTORY");

    my @loginIDarray = split(/\s/, uc($loginid));
    foreach my $loginID (@loginIDarray) {
        if ($loginID =~ /^\D+\d+$/) {
            Bar("$loginID Login History");

            my $client = BOM::Platform::Client->new({ loginid => $loginID });
            my $login_history_result = $client->find_login_history(
                sort_by => 'login_date desc',
                limit   => 100
            );

            print '<pre>';
            if (not $login_history_result) {
                print '<p>There is no login history record for client [' . $loginID . ']</p>';
            }

            foreach my $login_history (@{$login_history_result}) {
                my $login_date        = $login_history->login_date;
                my $login_status      = $login_history->login_successful ? 'ok' : 'failed';
                my $login_environment = $login_history->login_environment;

                print "$login_date $login_status $login_environment\n";
            }
            print '</pre>';
        }
    }
}

code_exit_BO();
