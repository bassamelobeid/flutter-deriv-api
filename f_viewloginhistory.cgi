#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::User::Client;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

if (my $email_list = request()->param('email')) {
    BrokerPresentation("USER LOGIN HISTORY");

    foreach my $email (split(/\s+/, lc($email_list))) {
        Bar($email . " Login History");
        my $user = BOM::User->new(email => $email);
        no warnings 'numeric';    ## no critic (ProhibitNoWarnings)
        my $limit = int(request()->param('limit') // 100);
        my $history;
        if ($user) {
            $history = $user->login_history(
                order => 'desc',
                $limit > 0 ? (limit => $limit) : (),
            );
        }
        BOM::Backoffice::Request::template()->process(
            'backoffice/user_login_history.html.tt',
            {
                user    => $user,
                history => $history,
                limit   => $limit
            });
    }
}
code_exit_BO();
