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

PrintContentType();

BrokerPresentation('Client Impersonate');

Bar('Client Impersonate');

my $login         = request()->param('impersonate_loginid');
my $broker        = request()->param('broker') // request()->broker_code;
my $encoded_login = encode_entities($login);

if ($login !~ /^$broker\d+$/) {
    print "Error: Wrong Login ID $encoded_login, please select correct broker code";
    code_exit_BO();
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => uc $login, db_operation => 'backoffice_replica'}) };

if (not $client) {
    print "Error: Wrong Login ID ($encoded_login) could not get client instance";
    code_exit_BO();
}

if ($client->status->disabled || $client->status->duplicate_account) {
    my $reason = $client->status->disabled ? 'disabled' : 'duplicated';

    print "Error: Client cannot be impersonated, as the client account is $reason";
    code_exit_BO();
}

my $oauth_model = BOM::Database::Model::OAuth->new;
# backoffice app_id is 4
my $bo_app = $oauth_model->get_app(1, 4);

my ($access_token) = $oauth_model->store_access_token_only($bo_app->{app_id}, $login);
if (not $access_token) {
    print "Error: not able to impersonate $encoded_login";
}

print "<p>$encoded_login impersonated, please click the button below to view client account:</p>";
print "<p><a class='btn btn--primary' href='"
    . $bo_app->{redirect_uri}
    . "?acct1=$login&token1=$access_token' target='_blank'>View client account</a></p>";
print "<p class='error'>MAKE SURE YOU LOGOUT FROM CLIENT ACCOUNT ON BINARY.COM AFTER YOU ARE DONE!</p>";

code_exit_BO();
