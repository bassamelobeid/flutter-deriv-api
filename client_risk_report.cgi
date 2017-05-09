#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Client::Account;

use f_brokerincludeall;
use BOM::Backoffice::Request qw(request localize);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $loginid = request()->param('loginid');
BrokerPresentation('Show Risk Report For: ' . $loginid);

BOM::Backoffice::Auth0::can_access(['CS']);
my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

if (not $loginid) {
    print 'Invalid loginid.';
    code_exit_BO();
}

my $client = Client::Account::get_instance({'loginid' => $loginid}) || die "bad client $loginid";

code_exit_BO();
