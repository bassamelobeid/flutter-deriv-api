#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::User::Client;
use BOM::Backoffice::UserService;
use BOM::Service;
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
        if ($user) {
            my $limit     = 200;
            my $user_data = BOM::Service::user(
                context         => BOM::Backoffice::UserService::get_context(),
                command         => 'get_login_history',
                user_id         => $user->{email},
                limit           => $limit,
                show_backoffice => 1,
            );

            unless ($user_data->{status} eq 'ok') {
                code_exit_BO("<p>" . $user_data->{message} . "</p>", "Error - Failed to read login history from user service");
            }
            BOM::Backoffice::Request::template()->process(
                'backoffice/user_login_history.html.tt',
                {
                    user    => $user,
                    history => $user_data->{login_history},
                    limit   => $limit
                });
        } else {
            code_exit_BO("<p>Unknown user: $email</p>", "Error - Unknown user");
        }
    }
}
code_exit_BO();
