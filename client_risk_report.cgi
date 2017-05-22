#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Client::Account;

use f_brokerincludeall;
use BOM::RiskReporting::Client;
use Client::Account;
use BOM::Backoffice::Request qw(request localize);
use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

PrintContentType();

my $loginid = request()->param('loginid');
BrokerPresentation('Show Risk Report For: ' . $loginid);

BOM::Backoffice::Auth0::can_access([]);
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $client = Client::Account::get_instance({'loginid' => $loginid}) || code_exit_BO('Invalid loginid.');

my $data;
if (request()->param('req') eq 'generate') {
    $data = BOM::RiskReporting::Client->new({client => $client})->generate($clerk);
} else {
    $data = BOM::RiskReporting::Client->new({client => $client})->generate;
}

if (request()->param('req') eq 'comment') {
    $data = BOM::RiskReporting::Client->new({client => $client})->add_comment($clerk, request()->param('comment'));
}

show_data($data);

sub show_data {
    my $data = shift;
    use Data::Dumper;

    print Data::Dumper::Dumper($data);
}
code_exit_BO();
