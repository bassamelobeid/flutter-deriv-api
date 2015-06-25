#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Database::AutoGenerated::Rose::Users::LoginHistory::Manager;
use BOM::Database::UserDB;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $ip = request()->param('ip');
BrokerPresentation("IP SEARCH FOR $ip");
BOM::Platform::Auth0::can_access(['CS']);
my $broker = request()->broker->code;

if ($ip !~ /^\d+\.\d+\.\d+\.\d+$/) {
    print "Invalid IP $ip";
    code_exit_BO();
}

Bar("Searching for Emails corresponding to $ip");
my $last_login_age = request()->param('lastndays') || 10;

# IP search from users.login_history table
my $logins = BOM::Database::AutoGenerated::Rose::Users::LoginHistory::Manager->get_login_history(
    db              => BOM::Database::UserDB::rose_db(),
    require_objects => ['binary_user'],
    query           =>
    [
        successful      => 1,
        environment     => { like => 'IP='.$ip.' %' },
        history_date    => { gt => DateTime->today()->subtract(days => $last_login_age) },
    ],
    sort_by         => 't1.history_date DESC'
);

unless ($logins and @{$logins} > 0) {
    print "No logins found for IP address [$ip] in the last [$last_login_age] days";
    code_exit_BO();
}

foreach my $login (@{$logins}) {
    my $email   = $login->binary_user->email;
    my $date    = $login->history_date;
    my $action  = $login->action;

    print "<br>$email date= $date ip= $ip action= $action";
}
code_exit_BO();
