package BOM::Backoffice::Sysinit;

use warnings;
use strict;

use Time::HiRes ();
use Guard;
use File::Copy;
use Path::Tiny;
use Plack::App::CGIBin::Streaming;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
use BOM::Backoffice::Request::Base;
use BOM::Backoffice::Request qw(request localize);
use BOM::Platform::Config;
use BOM::Platform::Chronicle;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Try::Tiny::Except ();    # should be preloaded as early as possible
                             # this statement here is merely a comment.

my $permissions = {
    'f_broker_login.cgi'              => undef,                          #login page is allowed for all
    'login.cgi'                       => undef,                          #login page is allowed for all
    'second_step_auth.cgi'            => undef,
    'batch_payments.cgi'              => ['Payments'],
    'c_listclientlimits.cgi'          => ['CS'],
    'client_email.cgi'                => ['CS'],
    'client_impersonate.cgi'          => ['CS'],
    'client_risk_report.cgi'          => ['Compliance'],
    'easy_search.cgi'                 => ['CS'],
    'f_accountingreports.cgi'         => ['Accounts'],
    'f_bet_iv.cgi'                    => ['Quants'],
    'f_bo_enquiry.cgi'                => ['CS'],
    'f_clientloginid.cgi'             => ['CS'],
    'f_clientloginid_edit.cgi'        => ['CS'],
    'f_clientloginid_newpassword.cgi' => ['CS'],
    'f_dailyico.cgi'                  => ['Quants'],
    'f_dailyico_graph.cgi'            => ['Quants'],
    'f_dailyturnoverreport.cgi'       => ['Accounts', 'Quants', 'IT'],
    'f_dynamic_settings.cgi'                                   => ['Quants',   'IT'],       # it has extra internal logic inside
    'f_formatdailysummary.cgi'                                 => ['Quants'],
    'f_investigative.cgi'                                      => ['CS'],
    'f_makeclientdcc.cgi'                                      => ['CS'],
    'f_makedcc.cgi'                                            => ['Payments'],
    'f_manager.cgi'                                            => ['Payments'],
    'f_manager_confodeposit.cgi'                               => ['Payments'],
    'f_manager_crypto.cgi'                                     => ['Payments'],
    'f_manager_history.cgi'                                    => ['CS'],
    'f_manager_statement.cgi'                                  => ['CS'],
    'f_popupclientsearch.cgi'                                  => ['CS'],
    'f_profit_check.cgi'                                       => ['CS'],
    'f_profit_table.cgi'                                       => ['CS'],
    'f_promotional.cgi'                                        => ['Marketing'],
    'f_promotional_processing.cgi'                             => ['Marketing'],
    'f_rescind_freegift.cgi'                                   => ['Payments'],
    'f_rescind_listofaccounts.cgi'                             => ['Payments'],
    'f_rtquoteslogin.cgi'                                      => ['Quants'],
    'f_save.cgi'                                               => ['Quants'],
    'f_setting_paymentagent.cgi'                               => ['CS'],
    'f_setting_selfexclusion.cgi'                              => ['CS'],
    'f_show.cgi'                                               => ['Accounts'],
    'f_upload_holidays.cgi'                                    => ['Quants'],
    'f_viewclientsubset.cgi'                                   => ['CS'],
    'f_viewloginhistory.cgi'                                   => ['CS'],
    'fetch_myaffiliate_payment.cgi'                            => ['Marketing'],
    'ip_search.cgi'                                            => ['CS'],
    'monthly_client_report.cgi'                                => ['Accounts'],
    'monthly_payments_report.cgi'                              => ['Accounts'],
    'open_contracts_report.cgi'                                => ['Accounts', 'Quants'],
    'promocode_edit.cgi'                                       => ['Marketing'],
    'quant/edit_interest_rate.cgi'                             => ['Quants'],
    'quant/market_data_mgmt/quant_market_tools_backoffice.cgi' => ['Quants'],
    'quant/pricing/bpot.cgi'                                   => ['Quants'],
    'quant/pricing/contract_details.cgi'                       => ['Quants'],
    'quant/pricing/f_dealer.cgi'                               => ['Quants'],
    'quant/product_management.cgi'                             => ['Quants'],
    'quant/settle_contracts.cgi'                               => ['Quants'],
    'rtquotes_displayallgraphs.cgi'                            => ['Quants'],
    'show_audit_trail.cgi'                                     => ['CS'],
    'trusted_client_edit.cgi'                                  => ['CS'],
    'untrusted_client_edit.cgi'                                => ['CS'],
    'view_192_raw_response.cgi'                                => ['CS'],
    #following files used to have no access check inside
    'download_document.cgi'              => ['CS', 'Compliance', 'Quants', 'IT'],
    'f_bbdl_download.cgi'                => ['Quants'],
    'f_bbdl_list_directory.cgi'          => ['Quants'],
    'f_bbdl_scheduled_request_files.cgi' => ['Quants'],
    'f_bbdl_upload.cgi'                  => ['Quants'],
    'f_bbdl_upload_request_files.cgi'    => ['Quants'],
    'f_client_combined_audit.cgi'        => ['CS'],
    'f_client_deskcom.cgi'               => ['CS'],
    'f_quant_query.cgi'                  => ['Quants'],
};

sub init {
    $ENV{REQUEST_STARTTIME} = Time::HiRes::time;    ## no critic (RequireLocalizedPunctuationVars)
    $^T                     = time;                 ## no critic (RequireLocalizedPunctuationVars)
                                                    # Turn off any outstanding alarm, perhaps from a previous request in this mod_perl process,
                                                    # while we figure out how we might want to alarm on this particular request.
    alarm(0);
    build_request();

    if (BOM::Platform::Config::on_qa()) {
        # Sometimes it is needed to do some stuff on QA's backoffice with production databases (backpricing for Quants/Japan checking/etc)
        # here we implemenet an easy way of selection of needed database
        my $needed_service =
            BOM::Backoffice::Cookie::get_cookie('backprice') ? '/home/nobody/.pg_service_backprice.conf' : '/home/nobody/.pg_service.conf';

        #in case backprice settings have changed for session, make sure this fork uses newer pg_service file, but clearing Chronicle instance
        if (!$ENV{PGSERVICEFILE} || $needed_service ne $ENV{PGSERVICEFILE}) {
            BOM::Platform::Chronicle::clear_connections();
            $ENV{PGSERVICEFILE} = $needed_service;    ## no critic (RequireLocalizedPunctuationVars)
        }
    }
    if (request()->from_ui) {
        {
            no strict;                                ## no critic (ProhibitNoStrict)
            undef ${"main::input"}
        }
        my $http_handler = Plack::App::CGIBin::Streaming->request;

        my $timeout = 1800;

        $SIG{ALRM} = sub {                            ## no critic (RequireLocalizedPunctuationVars)
            my $runtime = time - $^T;

            warn("Panic timeout after $runtime seconds");
            _show_error_and_exit(
                'The page has timed out. This may be due to a slow Internet connection, or to excess load on our servers.  Please try again in a few moments.'
            );

        };
        alarm($timeout);

        $http_handler->register_cleanup(
            sub {
                delete @ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/};
                BOM::Database::Rose::DB->db_cache->finish_request_cycle;
                alarm 0;
            });

        $ENV{AUDIT_STAFF_NAME} = BOM::Backoffice::Cookie::get_staff();    ## no critic (RequireLocalizedPunctuationVars)
        $ENV{AUDIT_STAFF_IP}   = request()->client_ip;                    ## no critic (RequireLocalizedPunctuationVars)

        request()->http_handler($http_handler);

        if (!_check_access($http_handler->script_name)) {
            _show_error_and_exit('Access to ' . $http_handler->script_name . ' is not allowed');
        }
    } else {
        # We can ignore the alarm because we're not serving a web request here.
        # This is most likely happening in tests, long execution of which should be caught elsewhere.
        $SIG{'ALRM'} = 'IGNORE';    ## no critic (RequireLocalizedPunctuationVars)
    }

    log_bo_access();
    return;
}

sub build_request {
    if (Plack::App::CGIBin::Streaming->request) {    # is web server ?
        $CGI::POST_MAX        = 8000 * 1024;         # max 8MB posts
        $CGI::DISABLE_UPLOADS = 0;
        return request(
            BOM::Backoffice::Request::Base::from_cgi({
                    cgi         => CGI->new,
                    http_cookie => $ENV{'HTTP_COOKIE'},
                }));
    }
    return;
}

sub log_bo_access {

    $ENV{'REMOTE_ADDR'} = request()->client_ip;    ## no critic (RequireLocalizedPunctuationVars)

    # log it
    my $l;
    foreach my $k (keys %{request()->params}) {
        if ($k =~ /pass/) {
            next;
        }
        my $v = request()->param($k);
        $v =~ s/[\r\n\f\t]/ /g;
        $v =~ s/[^\w\s\,\.\-\+\"\'\=\+\-\*\%\$\#\@\!\~\?\/\>\<]/ /gm;

        if (length $v > 50) {
            $l .= "$k=" . substr($v, 0, 50) . "... ";
        } else {
            $l .= "$k=$v ";
        }
    }
    $l //= '(no parameters)';
    my $staffname = BOM::Backoffice::Cookie::get_staff();
    $staffname ||= 'unauthenticated';
    my $s = $0;
    $s =~ s{^\Q/home/website/www}{};
    my $log = BOM::Backoffice::Config::config->{log}->{staff};
    $log =~ s/%STAFFNAME%/$staffname/g;

    if ((-s $log or 0) > 750000) {
        File::Copy::move($log, "$log.1");
    }
    Path::Tiny::path($log)->append_utf8(Date::Utility->new->datetime . " $s $l\n");

    return;
}

sub _show_error_and_exit {
    my $error   = shift;
    my $timenow = Date::Utility->new->datetime;
    warn "_show_error_and_exit: $error (IP: " . request()->client_ip . ')';
    # this can be duplicated for ALARM message, but not an issue
    PrintContentType();
    print '<div id="page_timeout_notice" class="aligncenter">'
        . '<p class="normalfonterror">'
        . $timenow . ' '
        . localize($error) . '</p>'
        . '<p class="normalfonterror">'
        . '<a href="javascript:document.location.reload();"><b>'
        . localize('Reload page')
        . '</b></a> '
        . '</div>';
    BOM::Backoffice::Request::request_completed();
    exit;
}

sub _check_access {
    my $script = shift // '';
    $script =~ s/^\///;
    # don't allow access to unknown scripts
    return 0 unless exists $permissions->{$script};
    # and allow access if permissions are undef
    return 1 unless defined $permissions->{$script};
    return BOM::Backoffice::Auth0::has_authorisation($permissions->{$script});
}

1;

