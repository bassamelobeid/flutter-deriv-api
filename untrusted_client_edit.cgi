#!/usr/bin/perl
package main;

use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

use BOM::System::RedisReplicated;

PrintContentType();
BrokerPresentation("UNTRUSTED/DISABLE CLIENT");

my $broker = request()->broker->code;
my $staff  = BOM::Backoffice::Auth0::can_access(['CS']);
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $clientID           = uc request()->param('login_id');
my $action             = request()->param('untrusted_action');
my $removed            = request()->param('removed');
my $client_status_type = request()->param('untrusted_action_type');
my $reason             = request()->param('untrusted_reason');
my $additional_info    = request()->param('additional_info');
my $file_path          = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/";
my $file_name          = "$broker.$client_status_type";

# append the input text if additional infomation exist
$reason = '' unless ($reason);
$reason = ($additional_info) ? $reason . ' - ' . $additional_info : $reason;

local $\ = "\n";
my ($printline, @invalid_logins);

Bar("UNTRUSTED/DISABLE CLIENT");

LOGIN:
foreach my $login_id (split(/\s+/, $clientID)) {
    my $client = BOM::Platform::Client::get_instance({'loginid' => $login_id});
    if (not $client) {
        push @invalid_logins, $login_id;
        next LOGIN;
    }

    # check invalid reason
    if ($reason =~ /SELECT A REASON/) {
        print "<br /><font color=red><b>ERROR : Reason is not specified.</b></font><br /><br />";
        code_exit_BO();
    }

    # check invalid action
    if ($client_status_type =~ /SELECT AN ACTION/) {
        print "<br /><font color=red><b>ERROR : The action to perform is not specified.</b></font><br /><br />";
        code_exit_BO();
    }

    # BUILD MESSAGE TO PRINT TO SCREEN
    my $insert_error_msg =
        "<font color=red><b>ERROR :</font></b>&nbsp;&nbsp;<b>$login_id $reason ($clerk)</b>&nbsp;&nbsp;has not been saved to  <b>$file_name</b>";
    my $insert_success_msg =
        "<font color=green><b>SUCCESS :</font></b>&nbsp;&nbsp;<b>$login_id $reason ($clerk)</b>&nbsp;&nbsp;has been saved to  <b>$file_name</b>";
    my $remove_error_msg = "<font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Failed to enable this client <b>$login_id</b>. Please try again.";
    my $remove_success_msg =
        "<font color=green><b>SUCCESS :</b></font>&nbsp;&nbsp;<b>$login_id $reason ($clerk)</b>&nbsp;&nbsp;has been removed from  <b>$file_name</b>";

    # DISABLED/CLOSED CLIENT LOGIN
    if ($client_status_type eq 'disabledlogins') {
        if ($action eq 'insert_data') {
            $client->set_status('disabled', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
            my @tokens = BOM::System::RedisReplicated::redis_read->keys('LOGIN_SESSION::*');
            for my $token (@tokens){
                my $cookie = BOM::Platform::SessionCookie->new({token => $token});
                $cookie->end_session if $cookie->loginid eq $client->loginid;
            }
        }
        # remove client from $broker.disabledlogins
        elsif ($action eq 'remove_data') {
            $client->clr_status('disabled');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
    }
    # LOCK CASHIER LOGIN
    elsif ($client_status_type eq 'lockcashierlogins') {
        if ($action eq 'insert_data') {
            $client->set_status('cashier_locked', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
        } elsif ($action eq 'remove_data') {
            $client->clr_status('cashier_locked');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
    }
    # UNWELCOME LOGIN
    elsif ($client_status_type eq 'unwelcomelogins') {
        if ($action eq 'insert_data') {
            $client->set_status('unwelcome', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
        } elsif ($action eq 'remove_data') {
            $client->clr_status('unwelcome');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
    } elsif ($client_status_type eq 'lockwithdrawal') {
        if ($action eq 'insert_data') {
            $client->set_status('withdrawal_locked', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
        } elsif ($action eq 'remove_data') {
            $client->clr_status('withdrawal_locked');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
    } elsif ($client_status_type eq 'jpactivationpending') {
        if ($action eq 'insert_data') {
            $client->set_status('jp_activation_pending', $clerk, $reason);
            $printline = $client->save ? $insert_success_msg : $insert_error_msg;
        } elsif ($action eq 'remove_data') {
            $client->clr_status('jp_activation_pending');
            $printline = $client->save ? $remove_success_msg : $remove_error_msg;
        }
    }

    # print success/fail message
    print $printline;
}

if (scalar @invalid_logins > 0) {
    print "<font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Unable to find these clients <b>"
        . join(',', @invalid_logins)
        . "</b>. Please check and try again.";
}

code_exit_BO();
