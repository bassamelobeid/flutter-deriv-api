#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::User::Client;
use HTML::Entities;
use Syntax::Keyword::Try;
use BOM::Platform::Token::API;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("UNTRUSTED/DISABLE CLIENT");

my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::get_staffname();

my $clientID           = uc request()->param('login_id');
my $action             = request()->param('untrusted_action');
my $removed            = request()->param('removed');
my $client_status_type = request()->param('untrusted_action_type');
my $reason             = request()->param('untrusted_reason');
my $additional_info    = request()->param('additional_info');
my $file_path          = BOM::Config::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/";
my $file_name          = "$broker.$client_status_type";

# append the input text if additional infomation exist
$reason = '' unless ($reason);
$reason = ($additional_info) ? $reason . ' - ' . $additional_info : $reason;

local $\ = "\n";
my ($printline, @invalid_logins);

Bar("UNTRUSTED/DISABLE CLIENT");

LOGIN:
foreach my $login_id (split(/\s+/, $clientID)) {
    my $client = eval { BOM::User::Client::get_instance({'loginid' => $login_id}) };
    if (not $client) {
        push @invalid_logins, encode_entities($login_id);
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

    my %common_args_for_execute_method = (
        client    => $client,
        clerk     => $clerk,
        reason    => $reason,
        file_name => $file_name
    );

    # DISABLED/CLOSED CLIENT LOGIN
    if ($client_status_type eq 'disabledlogins') {
        if ($action eq 'insert_data') {
            #should check portfolio
            if (@{get_open_contracts($client)}) {
                my $encoded_login_id = link_for_clientloginid_edit($login_id);
                $printline =
                    "<font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Account <b>$encoded_login_id</b> cannot be marked as disabled as account has open positions. Please check account portfolio.";
            } else {
                $printline = execute_set_status({%common_args_for_execute_method, status_code => 'disabled'});
            }
        }
        # remove client from $broker.disabledlogins
        elsif ($action eq 'remove_status') {
            $printline = execute_remove_status({%common_args_for_execute_method, status_code => 'disabled'});
        }
    } elsif ($client_status_type eq 'duplicateaccount') {
        if ($action eq 'insert_data') {
            $printline = execute_set_status({
                    %common_args_for_execute_method,
                    override => sub {
                        $client->status->set('duplicate_account', $clerk, $reason);
                        my $m = BOM::Platform::Token::API->new;
                        $m->remove_by_loginid($client->loginid);
                    }
                });
        } elsif ($action eq 'remove_status') {
            $printline = execute_remove_status->({%common_args_for_execute_method, status_code => 'duplicate_account'});
        }
    } elsif ($client_status_type eq 'professionalrequested') {
        if ($action eq 'remove_status') {
            $printline = execute_remove_status({
                    %common_args_for_execute_method,
                    override => sub {
                        $client->status->multi_set_clear({
                            set        => ['professional_rejected'],
                            clear      => ['professional_requested'],
                            staff_name => $clerk,
                            reason     => 'Professional request rejected'
                        });
                    }
                });
        }
    } else {
        my $status_code = get_untrusted_type_by_linktype($client_status_type)->{code};

        if ($action eq 'insert_data') {
            $printline = execute_set_status({%common_args_for_execute_method, status_code => $status_code});
        } elsif ($action eq 'remove_status') {
            $printline = execute_remove_status({%common_args_for_execute_method, status_code => $status_code});
        }
    }

    # print success/fail message
    print $printline;

    if ($printline =~ /SUCCESS/) {
        print '<br/><br/>';
        my $status_code = get_untrusted_type_by_linktype($client_status_type)->{code};

        if ($action eq 'insert_data') {
            print link_for_copy_status_status_to_siblings(
                $login_id,
                $status_code,
                {
                    enabled  => 'Do you need to set the status to the remaining landing company siblings? Click here.',
                    disabled => ''
                });
        } elsif ($action eq 'remove_status') {
            print link_for_remove_status_from_all_siblings(
                $login_id,
                $status_code,
                {
                    enabled  => 'Do you need to remove the status from the remaining landing company siblings? Click here.',
                    disabled => ''
                });
        }
    }
}

if (scalar @invalid_logins > 0) {
    print "<font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Unable to find these clients <b>"
        . join(',', @invalid_logins)
        . "</b>. Please check and try again.";
}

code_exit_BO();

sub execute_set_status {
    my $params = shift;
    my $client = $params->{client};

    my $encoded_login_id = link_for_clientloginid_edit($client->loginid);
    my $encoded_reason   = encode_entities($params->{reason});
    my $encoded_clerk    = encode_entities($params->{clerk});
    my $file_name        = $params->{file_name};

    try {
        if ($params->{override}) {
            $params->{override}->();
        } else {
            $client->status->set($params->{status_code}, $params->{clerk}, $params->{reason});
        }

        return
            "<font color=green><b>SUCCESS :</font></b>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been saved to  <b>$file_name</b>";
    }
    catch {
        return
            "<font color=red><b>ERROR :</font></b>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved to  <b>$file_name</b>";
    }
}

sub execute_remove_status {
    my $params = shift;
    my $client = $params->{client};

    my $encoded_login_id = link_for_clientloginid_edit($client->loginid);
    my $encoded_reason   = encode_entities($params->{reason});
    my $encoded_clerk    = encode_entities($params->{clerk});
    my $file_name        = $params->{file_name};

    try {
        if ($params->{override}) {
            $params->{override}->();
        } else {
            my $client_status_cleaner_method_name = 'clear_' . $params->{status_code};

            $client->status->$client_status_cleaner_method_name;
        }

        return
            "<font color=green><b>SUCCESS :</b></font>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been removed from  <b>$file_name</b>";
    }
    catch {
        return "<font color=red><b>ERROR :</b></font>&nbsp;&nbsp;Failed to enable this client <b>$encoded_login_id</b>. Please try again.";
    }
}
