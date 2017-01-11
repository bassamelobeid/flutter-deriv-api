#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use Client::Account;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BOM::Backoffice::Auth0::can_access(['CS']);

if (my $email_list = request()->param('email')) {
    BrokerPresentation("USER LOGIN HISTORY");

    foreach my $email (split(/\s+/, lc($email_list))) {
        Bar(encode_entities($email) . " Login History");
        my $user = BOM::Platform::User->new({email => $email});
        my $history;
        if ($user) {
            $history = $user->find_login_history(
                sort_by => 'history_date desc',
                limit   => 100
            );
        }
        BOM::Backoffice::Request::template->process(
            'backoffice/user_login_history.html.tt',
            {
                user    => $user,
                history => $history
            });
    }
}

code_exit_BO();
