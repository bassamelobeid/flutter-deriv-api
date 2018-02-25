#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use BOM::User::Client;

use Text::Trim;
use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("TRUSTED CLIENT");

my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $dbloc           = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $clientID        = uc request()->param('login_id');
my $action          = request()->param('trusted_action');
my $action_type     = request()->param('trusted_action_type');
my $reason          = request()->param('trusted_reason');
my $additional_info = request()->param('additional_info');
my $remove_action   = request()->param('removed');
my $email           = request()->param('email_addr');
my $DCcode          = request()->param('dcc');
my $DCstaff         = request()->param('dccstaff');

# append the input text if additional infomation exist
$reason = '' unless ($reason);
$reason = ($additional_info) ? $reason . ' - ' . $additional_info : $reason;

local $\ = "\n";
my $file_path = "$dbloc/f_broker/$broker/";
my $file_name = "$broker.$action_type";
my ($client, $printline, @invalid_logins);

Bar("TRUSTED CLIENT");

# check invalid action
if ($action_type =~ /SELECT A DATABASE TO VIEW/) {
    print "<br /><font color=red><b>ERROR : The action to perform is not specified.</b></font><br /><br />";
    code_exit_BO();
}

my $encoded_clientID = encode_entities($clientID);
if ($action_type !~ /(oklogins)/) {
    $clientID = rtrim($clientID);
    $client = BOM::User::Client::get_instance({'loginid' => $clientID});

    if (not $client) {
        print "<br /><font color=red><b>ERROR : Bad loginID ' $encoded_clientID '</b></font><br /><br />";
        code_exit_BO();
    }
}

# check invalid reason
if ($reason =~ /SELECT A REASON/) {
    print "<br /><font color=red><b>ERROR : Reason is not specified.</b></font><br /><br />";
    code_exit_BO();
}

######################################################################
## BUILD MESSAGE TO PRINT TO SCREEN                                 ##
######################################################################
my $encoded_reason = encode_entities($reason);
my $encoded_clerk  = encode_entities($clerk);
my $insert_error_msg =
    "<br /><font color=red><b>ERROR :</font></b>&nbsp;&nbsp;<b>$encoded_clientID $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved<br /><br />";

my $insert_success_msg =
    "<br /><font color=green><b>SUCCESS :</font></b>&nbsp;&nbsp;<b>$encoded_clientID $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been saved successfully<br /><br />";

my $remove_error_msg =
    "<br /><font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Failed to remove this client <b>$encoded_clientID</b>. Please try again.<br /><br />";

my $remove_success_msg =
    "<br /><font color=green><b>SUCCESS :</b></font>&nbsp;&nbsp;<b>$encoded_clientID $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been removed successfully<br /><br />";

######################################################################
## ALLOW OK LOGINS                                                  ##
######################################################################
if ($action_type eq 'oklogins') {
    LOGIN:
    foreach my $login_id (split(/\s+/, $clientID)) {
        my $encoded_login_id = encode_entities($login_id);
        my $client = BOM::User::Client::get_instance({'loginid' => $login_id});
        if (not $client) {
            push @invalid_logins, $login_id;
            next LOGIN;
        }

        if ($action eq 'insert_data') {
            $client->set_status('ok', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
        } elsif ($action eq 'remove_data') {
            $client->clr_status('ok');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
        # print success/fail message
        $printline =~ s/$encoded_clientID/$encoded_login_id/g;
        print $printline;
    }
} else {
    die " Invalid action type [" . encode_entities($action_type) . "]";
}

# handle invalid login
if (@invalid_logins) {
    print '<br /><font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Failed to save these invalid login ID: <b>'
        . join(', ', map { encode_entities($_) } @invalid_logins)
        . '</b><br /><br />';
}

code_exit_BO();
