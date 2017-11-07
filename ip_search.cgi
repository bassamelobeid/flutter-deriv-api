#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::User;
use BOM::Database::UserDB;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $ip        = request()->param('ip')        // '';
my $loginid   = request()->param('loginid')   // '';
my $date_from = request()->param('date_from') // '2016-01-01';
my $date_to   = request()->param('date_to')   // '2018-01-01';
Bar("IP Search");
BrokerPresentation("IP SEARCH FOR");
my $broker = request()->broker_code;

my $last_login_age = request()->param('lastndays') || 10;
my $logins;
my $suspected_logins;
# IP search from users.login_history table
if ($ip ne '') {
    my $encoded_ip = encode_entities($ip);
    if ($ip !~ /^\d+\.\d+\.\d+\.\d+$/) {
        print "Invalid IP $encoded_ip";
        code_exit_BO();
    }
    $logins = BOM::Database::UserDB::rose_db()->dbic->run(
        sub {
            $_->selectall_arrayref(
                "SELECT history_date, action, email FROM users.login_history_by_ip(?::INET, 'today'::TIMESTAMP - ?::INTERVAL)",
                {Slice => {}},
                $ip, "${last_login_age}d"
            );
        });

} elsif ($loginid ne '') {
# for some reason we have historically passed in an email address on 'loginid'... but now we will consider either one

    $suspected_logins = BOM::Database::UserDB::rose_db()->dbic->run(
        sub {
            $_->selectall_arrayref('
                SELECT history_date, logins
                FROM (
                    SELECT id FROM users.binary_user WHERE email = $1
                    UNION ALL
                    SELECT binary_user_id FROM users.loginid WHERE loginid = $1
                    LIMIT 1
                    ) u(id)
                CROSS JOIN LATERAL users.get_login_similarities(u.id, $2, $3)',
                {Slice => {}},
                $loginid, $date_from, $date_to
            );
        });
}

BOM::Backoffice::Request::template->process(
    'backoffice/ip_search.html.tt',
    {
        logins           => $logins,
        days             => $last_login_age,
        ip               => $ip,
        loginid          => $loginid,
        suspected_logins => $suspected_logins,
        date_from        => $date_from,
        date_to          => $date_to,
    }) || die BOM::Backoffice::Request::template->error();

code_exit_BO();
