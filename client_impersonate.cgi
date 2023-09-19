#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::Auth0;
use BOM::Database::Model::OAuth;
use BOM::User::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType http_redirect );
use BOM::Backoffice::Sysinit      ();
use BOM::DualControl;
use Date::Utility;
BOM::Backoffice::Sysinit::init();

# hard-coding the app names because CS team needs them to be as below
my $app_info = {
    id   => 16929,
    name => 'Deriv',
};

my $input   = request()->params;
my $title   = 'Client Impersonate';
my $loginid = $input->{'impersonate_loginid'} // '';
my $broker  = $input->{'broker'}              // request()->broker_code;
my ($dcc, $clerk);

sub print_title {
    PrintContentType();
    BrokerPresentation($title);
}

$clerk = BOM::Backoffice::Auth0::get_staffname();

my $encoded_login = encode_entities($loginid);

if ($loginid !~ /^$broker\d+$/) {
    print_title();
    code_exit_BO("Error: Wrong Login ID $encoded_login, please select correct broker code", $title);
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => uc $loginid, db_operation => 'backoffice_replica'}) };

if (not $client) {
    print_title();
    code_exit_BO("Error: wrong Login ID ($encoded_login) could not get client instance", $title);
}

if ($client->status->disabled || $client->status->duplicate_account) {
    my $reason = $client->status->disabled ? 'disabled' : 'duplicated';
    print_title();
    code_exit_BO("Error: Client cannot be impersonated, as the client account is $reason", $title);
}

if ($input->{'make_dcc'}) {
    print_title();
    $dcc = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transaction_type'}})->create_impersonate_control_code($loginid);

    BOM::Backoffice::Request::template()->process(
        'backoffice/dcc.html.tt',
        {
            code      => encode_entities($dcc),
            clerk     => $clerk,
            timestamp => Date::Utility->new->datetime_ddmmmyy_hhmmss
        });
    code_exit_BO();
} else {

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{'transaction_type'}})->validate_impersonate_control_code($input->{impersonate_dcc}, $loginid);

    if ($dcc_error) {
        print_title();
        code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg()));
    }
}

my $oauth_model = BOM::Database::Model::OAuth->new;
my $bo_app      = $oauth_model->get_app(1, 4);        # backoffice app_id is 4

my ($access_token) = $oauth_model->store_access_token_only($bo_app->{app_id}, $loginid);
if (not $access_token) {
    print_title();
    code_exit_BO("Error: not able to impersonate $encoded_login", $title);
}

my $app = $oauth_model->get_app(1, $app_info->{id});
if ($app) {
    http_redirect $app->{redirect_uri} . '?acct1=' . $loginid . '&token1=' . $access_token;
} else {
    print_title();
    print sprintf("<span class='error'>Error retrieving information of %s (%s) app.</span>", $app_info->{name}, $app_info->{id});
}

code_exit_BO();
