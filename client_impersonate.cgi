#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::Auth0;
use BOM::Database::Model::OAuth;
use BOM::Platform::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('Client Impersonate');
BOM::Backoffice::Auth0::can_access(['CS']);

Bar('Client Impersonate');

my $login = request()->param('impersonate_loginid');
my $broker = request()->param('broker') // request()->broker_code;

if ($login !~ /^$broker\d+$/) {
    print "Error: Wrong loginid $login, please select correct broker code";
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $login});
if (not $client) {
    print "Error: wrong loginid ($login) could not get client instance";
    code_exit_BO();
}

my $oauth_model = BOM::Database::Model::OAuth->new;
# backoffice app_id is 4
my $bo_app = $oauth_model->get_app(1, 4);

my ($access_token) = $oauth_model->store_access_token_only($bo_app->{app_id}, $login);
if (not $access_token) {
    print "Error: not able to impersonate $login";
}

print
    "$login impersonated, please click on link below to view client account. <b>MAKE SURE YOU LOGOUT FROM CLIENT ACCOUNT ON BINARY.COM AFTER YOU ARE DONE!</b><br>";

print "<a href='" . $bo_app->{redirect_uri} . "?acct1=$login&token1=$access_token' target='_blank'>Click here</a>";

code_exit_BO();
