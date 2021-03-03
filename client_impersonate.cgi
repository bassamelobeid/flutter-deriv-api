#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::Auth0;
use BOM::Database::Model::OAuth;
use BOM::User::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use constant IMPERSONATE_APPS => (
    1,        # Binary.com
    16929,    # Deriv.com (DTrader)
);

PrintContentType();

my $title = 'Client Impersonate';

BrokerPresentation($title);

my $loginid       = request()->param('impersonate_loginid');
my $broker        = request()->param('broker') // request()->broker_code;
my $encoded_login = encode_entities($loginid);

if ($loginid !~ /^$broker\d+$/) {
    code_exit_BO("Error: Wrong Login ID $encoded_login, please select correct broker code", $title);
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => uc $loginid, db_operation => 'backoffice_replica'}) };

if (not $client) {
    code_exit_BO("Error: wrong Login ID ($encoded_login) could not get client instance", $title);
}

if ($client->status->disabled || $client->status->duplicate_account) {
    my $reason = $client->status->disabled ? 'disabled' : 'duplicated';
    code_exit_BO("Error: Client cannot be impersonated, as the client account is $reason", $title);
}

my $oauth_model = BOM::Database::Model::OAuth->new;
my $bo_app      = $oauth_model->get_app(1, 4);        # backoffice app_id is 4

my ($access_token) = $oauth_model->store_access_token_only($bo_app->{app_id}, $loginid);
if (not $access_token) {
    code_exit_BO("Error: not able to impersonate $encoded_login", $title);
}

Bar($title);
print "<p><b>$encoded_login</b> impersonated, please click on the buttons below to view client's account:</p>";

print '<p>';
for my $app_id (IMPERSONATE_APPS) {
    my $app = $oauth_model->get_app(1, $app_id);
    print sprintf("<a class='btn btn--primary' href='%s?acct1=%s&token1=%s' target='_blank'>Impersonate %s</a>",
        $app->{redirect_uri}, $loginid, $access_token, $app->{name});
}
print '</p>';

print "<p class='error'>MAKE SURE YOU LOGOUT FROM CLIENT ACCOUNT ON THE WEBSITE AFTER YOU ARE DONE!</p>";

code_exit_BO();
