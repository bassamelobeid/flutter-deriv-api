#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::User::Client;
use HTML::Entities;
use Syntax::Keyword::Try;
use BOM::Platform::Token::API;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("UNTRUSTED/DISABLE CLIENT");

my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::get_staffname();

my $clientID           = uc(request()->param('login_id') // '');
my $action             = request()->param('untrusted_action');
my $removed            = request()->param('removed');
my $client_status_type = request()->param('untrusted_action_type');
my $reason             = request()->param('untrusted_reason') // '';
my $additional_info    = request()->param('additional_info');
my $p2p_approved       = request()->param('p2p_approved');

# check invalid reason
print_error_and_exit("Reason is not specified.") if ($reason =~ /SELECT A REASON/);

# check invalid action
print_error_and_exit("The action to perform is not specified.") if (!$client_status_type || $client_status_type =~ /SELECT AN ACTION/);

my $file_path = BOM::Config::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/";
my $file_name = "$broker.$client_status_type";

# append the input text if additional infomation exist
$reason = ($additional_info) ? $reason . ' - ' . $additional_info : $reason;

local $\ = "\n";
my ($printline, @invalid_logins);

$clientID || code_exit_BO('Login ID is mandatory.', "UNTRUSTED/DISABLE CLIENT");

Bar("UNTRUSTED/DISABLE CLIENT");

LOGIN:
foreach my $login_id (split(/\s+/, $clientID)) {
    my $client = eval { BOM::User::Client::get_instance({'loginid' => $login_id}) };
    if (not $client) {
        push @invalid_logins, encode_entities($login_id);
        next LOGIN;
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
                    "<span class='error'>ERROR:</span>&nbsp;&nbsp;Account <b>$encoded_login_id</b> cannot be marked as disabled as account has open positions. Please check account portfolio.";
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
                    status_code => 'duplicate_account',
                    override    => sub {
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
            if ($status_code eq 'allow_document_upload' && $reason eq 'Pending payout request') {
                notify_submission_of_documents_for_pending_payout($client);
            }
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

    my $p2p_advertiser = $client->p2p_advertiser_info;
    if ($p2p_advertiser and defined $p2p_approved) {
        # Setting statuses may change p2p advertiser approval via db trigger.
        # We need to fire an event if approval has changed.
        BOM::Platform::Event::Emitter::emit('p2p_advertiser_updated', {client_loginid => $client->loginid})
            if $p2p_approved ne $p2p_advertiser->{is_approved};
    }

}

if (scalar @invalid_logins > 0) {
    print "<span class='error'>ERROR:</span>&nbsp;&nbsp;Unable to find these clients <b>"
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
        my $status_code = $params->{status_code};
        if ($status_code) {
            return
                "<span class='error'>ERROR:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved, cannot override existing status reason</b>"
                if $client->status->$status_code;
            $client->status->set($status_code, $params->{clerk}, $params->{reason});
        }

        $params->{override}->() if $params->{override};

        return
            "<span class='success'>SUCCESS:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been saved to  <b>$file_name</b>";
    } catch {
        return
            "<span class='error'>ERROR:</span>>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved to  <b>$file_name</b>";
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
            "<span class='success'>SUCCESS:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been removed from  <b>$file_name</b>";
    } catch {
        return "<span class='error'>ERROR:</span>&nbsp;&nbsp;Failed to enable this client <b>$encoded_login_id</b>. Please try again.";
    }
}

sub print_error_and_exit {
    my $error_msg = shift;
    print "<p class='notify notify--danger'>ERROR : $error_msg</span>";
    code_exit_BO();
}

sub notify_submission_of_documents_for_pending_payout {
    my ($client) = @_;
    my $brand = Brands->new(name => 'deriv');

    my $req = BOM::Platform::Context::Request->new(
        brand_name => $brand->name,
        app_id     => $client->source,
    );
    BOM::Platform::Context::request($req);

    my $email_subject = localize('Verify your identity and address for your Deriv or Binary account');
    my $due_date      = Date::Utility->today->plus_time_interval('3d');
    my $email_data    = {
        name  => $client->first_name,
        title => localize("Just one more step to withdraw your funds"),
        date  => join(' ', $due_date->day_of_month, $due_date->month_as_string, $due_date->year),
    };
    send_email({
        to                    => $client->email,
        subject               => $email_subject,
        template_name         => 'pending_payout',
        template_args         => $email_data,
        template_loginid      => $client->loginid,
        email_content_is_html => 1,
        use_email_template    => 1,
        use_event             => 1,
        language              => $client->user->preferred_language
    });
}

