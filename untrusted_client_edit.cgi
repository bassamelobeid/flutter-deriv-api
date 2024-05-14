#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::User::Client;
use HTML::Entities;
use Syntax::Keyword::Try;
use BOM::Platform::Token::API;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email          qw(send_email);
use BOM::Platform::Utility        qw(verify_reactivation);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Utility;
use BOM::User::Client::Status;
use CGI;
use Log::Any      qw($log);
use Future::Utils qw( fmap_void );
use List::Util    qw( uniqstr );
use Net::Async::HTTP;

BOM::Backoffice::Sysinit::init();
my $is_readonly = BOM::Backoffice::Auth::has_readonly_access();
code_exit_BO(_get_display_error_message('Access Denied: you do not have access to make this change')) if $is_readonly;

PrintContentType();
BrokerPresentation("UNTRUSTED/DISABLE CLIENT");

my $broker      = request()->broker_code;
my $clerk       = BOM::Backoffice::Auth::get_staffname();
my $user_groups = BOM::Backoffice::Auth::get_staff_groups();

my $clientID = uc(request()->param('login_id') // '');
my $action   = request()->param('untrusted_action');
my $client_status_type =
    (request()->param('untrusted_sub_action_type') && request()->param('untrusted_sub_action_type') !~ /SELECT AN ACTION/)
    ? request()->param('untrusted_sub_action_type')
    : request()->param('untrusted_action_type');
my $status_code =
    ($client_status_type && $client_status_type !~ /SELECT AN ACTION/) ? get_untrusted_type_by_linktype($client_status_type)->{code} : undef;

my $status_parent = '';
$status_parent = (BOM::User::Client::Status::parent($status_code) // '') if $status_code;

my $bulk_loginids = request()->param('bulk_loginids') // '';
my $cgi           = request()->cgi;
my $DCcode        = request()->param('DCcode') // '';

my $reason         = request()->param('untrusted_reason') // '';
my $operation      = request()->param('status_op');
my $status_checked = request()->param('status_checked') // [];
$status_checked = [$status_checked] unless ref($status_checked);
my $additional_info = request()->param('additional_info');
my $p2p_approved    = request()->param('p2p_approved');
my $add_regex       = qr/^add|^sync/;
my $max_lines       = 2000;

if (my $error_message = write_operation_error()) {
    print_error_and_exit($error_message);
}

# check invalid Action
if (!$status_checked->@* && (!$client_status_type || $client_status_type =~ /SELECT AN ACTION/)) {
    print_error_and_exit("Action is not specified.");
}

my $file_name = "$broker.$client_status_type";
# append the input text if additional infomation exist
$reason = ($additional_info) ? $reason . ' - ' . $additional_info : $reason;
my ($file, $csv, $lines, @login_ids);
if ($bulk_loginids) {

# adding dcc verification code here
# start
    try {
        $file  = $cgi->upload('bulk_loginids');
        $csv   = Text::CSV->new({binary => 1});
        $lines = $csv->getline_all($file);
    } catch ($e) {
        code_exit_BO(_get_display_error_message("ERROR: " . $e)) if $e;
    }

    code_exit_BO(_get_display_error_message("ERROR: the given file is empty, please provide the required client_ids")) if (scalar($lines->@*) == 0);
    code_exit_BO(_get_display_error_message("ERROR: the number of client_ids exceeds limit of $max_lines please reduce the number of entries"))
        if scalar(@$lines) > $max_lines;
    unless (BOM::Backoffice::Auth::has_authorisation(['AntiFraud'])) {
        code_exit_BO(_get_display_error_message("ERROR: dual control code is mandatory for bulk status update")) if $DCcode eq '';
        my $dcc_error = BOM::DualControl->new({
                staff           => $clerk,
                transactiontype => "UPDATECLIENT_DETAILS_BULK"
            })->validate_batch_anonymization_control_code($DCcode, [map { join "\0" => $_->@* } $lines->@*]);
        code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;
    }
    for my $line (@$lines) {
        push @login_ids, $line->[0];
    }
    @login_ids = uniqstr grep { $_ } map { uc $_ } map { s/^\s+|\s+$//gr } map { $_->@* } \@login_ids;
    BOM::Platform::Event::Emitter::emit(
        'bulk_client_status_update',
        {
            loginids   => \@login_ids,
            properties => {
                status_op             => $operation,
                status_checked        => $status_checked,
                untrusted_action_type => $client_status_type,
                reason                => $reason,
                clerk                 => $clerk,
                user_groups           => $user_groups,
                file_name             => $file_name,
                action                => $action,
                status_code           => $status_code,
                req_params            => request()->params,
            }});
    code_exit_BO(_get_display_message("SUCCESS the client loginds update is triggered"), redirect());
# end
} else {
    $clientID || code_exit_BO('Login ID is mandatory.', "UNTRUSTED/DISABLE CLIENT", redirect());
    @login_ids = split(/\s+/, $clientID);
    print_error_and_exit("number of login id allowed exceeds the maximum allowed for this kind of status update.") if @login_ids > 5;

}

# check invalid Operation
if (!$operation || $operation =~ /SELECT AN OPERATION/) {
    print_error_and_exit("Operation is not specified.");
}

# check invalid Operation
if (!$status_checked->@* && $operation =~ /remove/) {
    print_error_and_exit("Status to be removed not specified. It should already exist.");
}
# check invalid Reason
if ($client_status_type && $client_status_type !~ /SELECT AN ACTION/ && $reason =~ /SELECT A REASON/) {
    print_error_and_exit("Reason is not specified.");
}

local $\ = "\n";
my ($printline, @invalid_logins);

Bar("UNTRUSTED/DISABLE CLIENT");
LOGIN:
foreach my $login_id (@login_ids) {
    my $client = eval { BOM::User::Client::get_instance({'loginid' => $login_id}) };

    if (not $client) {
        push @invalid_logins, encode_entities($login_id);
        next LOGIN;
    }

    my $old_db = $client->get_db();
    # assign write access to db_operation to perform client_status delete/copy operation
    $client->set_db('write') if 'write' ne $old_db;

    my %common_args_for_execute_method = (
        client      => $client,
        clerk       => $clerk,
        reason      => $reason,
        file_name   => $file_name,
        user_groups => $user_groups
    );

    # DISABLED/CLOSED CLIENT LOGIN
    if ($client_status_type =~ /SELECT AN ACTION/ || !$status_code) {
        #Skip (it's just a check)
    } elsif ($status_code eq 'disabled' || $status_parent eq 'disabled') {
        if ($action eq 'insert_data' && $operation =~ $add_regex) {
            #should check portfolio
            if (@{get_open_contracts($client)}) {
                my $encoded_login_id = link_for_clientloginid_edit($login_id);
                $printline =
                    "<span class='error'>ERROR:</span>&nbsp;&nbsp;Account <b>$encoded_login_id</b> cannot be marked as disabled as account has open positions. Please check account portfolio.";
            } else {
                $printline = execute_set_status({%common_args_for_execute_method, status_code => $status_code});
            }
        }
        # remove client from $broker.disabledlogins
        elsif ($action eq 'remove_status') {
            $printline = execute_remove_status({
                %common_args_for_execute_method,
                status_code  => $status_code,
                reactivating => 1
            });
        }
    } elsif (($status_code eq 'duplicate_account' || $status_parent eq 'duplicate_account')
        && ($operation =~ $add_regex))
    {
        if ($action eq 'insert_data') {
            $printline = execute_set_status({
                    %common_args_for_execute_method,
                    status_code => $status_code,
                    override    => sub {
                        my $m = BOM::Platform::Token::API->new;
                        $m->remove_by_loginid($client->loginid);
                    }
                });
        } elsif ($action eq 'remove_status') {
            $printline = execute_remove_status->({
                %common_args_for_execute_method,
                status_code  => $status_code,
                reactivating => 1
            });
        }
    } elsif (($status_code eq 'professional_requested' || $status_parent eq 'professional_requested')) {
        if ($action eq 'remove_status') {
            $printline = execute_remove_status({
                    %common_args_for_execute_method,
                    override => sub {
                        $client->status->multi_set_clear({
                            set        => ['professional_rejected'],
                            clear      => ['professional_requested', $status_code],
                            staff_name => $clerk,
                            reason     => 'Professional request rejected'
                        });
                    }
                });
        }
    } else {
        if ($action eq 'insert_data' && ($operation =~ $add_regex)) {
            $printline = execute_set_status({%common_args_for_execute_method, status_code => $status_code});
            if ($status_code eq 'allow_document_upload' && $reason eq 'Pending payout request') {
                BOM::User::Utility::notify_submission_of_documents_for_pending_payout($client);
            }
        } elsif ($action eq 'remove_status') {
            $printline = execute_remove_status({%common_args_for_execute_method, status_code => $status_code});
        }
    }

    $printline //= '';
    print $printline;

    if ($printline =~ /SUCCESS/) {
        print '<br/><br/>';

        if (!($operation eq 'sync_accounts' || $operation eq 'sync')) {
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

    p2p_advertiser_approval_check($client, request()->params);

    my $status_op_summary = BOM::Platform::Utility::status_op_processor(
        $client,
        {
            status_op             => $operation,
            status_checked        => $status_checked,
            untrusted_action_type => $client_status_type,
            reason                => $reason,
            clerk                 => $clerk,
            user_groups           => $user_groups,
        });
    # once db operation is done, set back db_operation to replica
    $client->set_db($old_db) if 'write' ne $old_db;

    print BOM::Backoffice::Utility::transform_summary_status_to_html($status_op_summary, $operation) if $status_op_summary;
}

if (scalar @invalid_logins > 0) {
    print "<span class='error'>ERROR:</span>&nbsp;&nbsp;Unable to find these clients <b>"
        . join(',', @invalid_logins)
        . "</b>. Please check and try again.";
}

code_exit_BO(redirect());

sub redirect {
    my $redirect_uri     = shift // request()->http_handler->env->{HTTP_REFERER};
    my $time_to_redirect = shift // 10;

    if ($redirect_uri) {
        print qq{
            </br></br><p style="text-align: center;" id="count-down">You will be redirected to the <a class="link" href="$redirect_uri">previous page</a> in $time_to_redirect seconds</p>
            <script>
                let time_to_redirect = $time_to_redirect;
    
                const redirect_message_field = document.querySelector('#count-down');
                const interval = setInterval(() => {
                    if (time_to_redirect-- === 1) {
                        clearInterval(interval);
                        window.location.replace('$redirect_uri');
                    }
    
                    const new_message = redirect_message_field.innerHTML.replace(/[0-9]+ seconds/, time_to_redirect + ' seconds');
                    redirect_message_field.innerHTML = new_message;
                }, 1000);
            </script>
        };
    } else {
        my $rand       = '?' . rand(9999);                                            # to avoid caching on these fast navigation links
        my $login_page = request()->url_for("backoffice/login.cgi", {_r => $rand});

        print qq{
                </br></br><p style="text-align: center;" id="redirect-login">Redirecting to <a class="link" href="$login_page">login page</a></p>
                <script>
                    window.location.replace('$login_page');
                </script>
            };
    }
}

sub execute_set_status {
    my $params           = shift;
    my $client           = $params->{client};
    my $encoded_login_id = link_for_clientloginid_edit($client->loginid);
    my $encoded_reason   = encode_entities($params->{reason});
    my $encoded_clerk    = encode_entities($params->{clerk});
    my $file_name        = $params->{file_name};
    my $user_groups      = $params->{user_groups};

    try {
        my $status_code = $params->{status_code};
        if ($status_code) {
            return
                "<span class='error'>ERROR:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved, cannot override existing status reason</b>"
                if $client->status->$status_code;

            return
                "<span class='error'>ERROR:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been saved, missing required permissions</b>"
                unless $client->status->can_execute($status_code, $user_groups, 'set');

            $client->status->upsert({
                status_code     => $status_code,
                staff_name      => $params->{clerk},
                reason          => $params->{reason},
                trigger_actions => 1
            });
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
    my $user_groups      = $params->{user_groups};

    try {
        if ($params->{override}) {
            $params->{override}->();
        } else {
            return
                "<span class='error'>ERROR:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has not been removed, missing required permissions</b>"
                unless $client->status->can_execute($params->{status_code}, $user_groups, 'remove');

            verify_reactivation($client, $params->{status_code});
            my $client_status_cleaner_method_name = 'clear_' . $params->{status_code};
            $client->status->$client_status_cleaner_method_name;
        }

        return
            "<span class='success'>SUCCESS:</span>&nbsp;&nbsp;<b>$encoded_login_id $encoded_reason ($encoded_clerk)</b>&nbsp;&nbsp;has been removed from  <b>$file_name</b>";
    } catch ($e) {
        return "<span class='error'>ERROR:</span>&nbsp;&nbsp;Failed to enable this client <b>$encoded_login_id</b>. $e";
    }
}

sub print_error_and_exit {
    my $error_msg = shift;
    print "<p class='notify notify--danger'>ERROR : $error_msg</span>";
    code_exit_BO(redirect());
}
