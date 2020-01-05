package BOM::Backoffice::Sysinit;

use warnings;
use strict;

use File::Copy;
use Guard;
use List::MoreUtils qw( any );
use Path::Tiny;
use Plack::App::CGIBin::Streaming;
use Time::HiRes ();

use BOM::Backoffice::Auth0;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request localize);
use BOM::Backoffice::Request::Base;
use BOM::Config::Chronicle;
use BOM::Config;

use Try::Tiny::Except ();    # should be preloaded as early as possible
                             # this statement here is merely a comment.

my $permissions = {
    'f_broker_login.cgi'   => ['ALL'],
    'login.cgi'            => ['ALL'],
    'second_step_auth.cgi' => ['ALL'],

    'batch_payments.cgi'           => ['Payments'],
    'f_makedcc.cgi'                => ['Payments'],
    'f_manager.cgi'                => ['Payments'],
    'f_manager_confodeposit.cgi'   => ['Payments'],
    'f_manager_crypto.cgi'         => ['Payments'],
    'f_rescind_freegift.cgi'       => ['Payments'],
    'f_rescind_listofaccounts.cgi' => ['Payments'],

    'monthly_client_report.cgi'   => ['Accounts'],
    'monthly_payments_report.cgi' => ['Accounts'],
    'f_accountingreports.cgi'     => ['Accounts'],
    'aggregate_balance.cgi'       => ['Accounts'],

    'promocode_edit.cgi'            => ['Marketing'],
    'f_promotional.cgi'             => ['Marketing'],
    'f_promotional_processing.cgi'  => ['Marketing'],
    'fetch_myaffiliate_payment.cgi' => ['Marketing'],
    'f_app_management.cgi'          => ['Marketing'],
    'f_payment_agent_list.cgi'      => ['Marketing'],
    'f_change_affiliates_token.cgi' => ['Marketing'],
    'f_ib_affiliate.cgi'            => ['Marketing'],

    'c_listclientlimits.cgi'          => ['CS'],
    'client_email.cgi'                => ['CS'],
    'client_impersonate.cgi'          => ['CS'],
    'easy_search.cgi'                 => ['CS'],
    'f_bo_enquiry.cgi'                => ['CS'],
    'f_clientloginid.cgi'             => ['CS'],
    'f_clientloginid_edit.cgi'        => ['CS'],
    'f_clientloginid_newpassword.cgi' => ['CS'],
    'f_send_statement.cgi'            => ['CS'],
    'f_investigative.cgi'             => ['CS'],
    'f_makeclientdcc.cgi'             => ['CS'],
    'f_manager_history.cgi'           => ['CS'],
    'f_manager_statement.cgi'         => ['CS'],
    'f_popupclientsearch.cgi'         => ['CS'],
    'f_profit_check.cgi'              => ['CS'],
    'f_profit_table.cgi'              => ['CS'],
    'f_setting_paymentagent.cgi'      => ['CS'],
    'f_setting_selfexclusion.cgi'     => ['CS'],
    'f_viewclientsubset.cgi'          => ['CS'],
    'f_viewloginhistory.cgi'          => ['CS'],
    'ip_search.cgi'                   => ['CS'],
    'show_audit_trail.cgi'            => ['CS'],
    'untrusted_client_edit.cgi'       => ['CS'],
    'sync_client_status.cgi'          => ['CS'],
    'view_192_raw_response.cgi'       => ['CS'],
    'f_client_deskcom.cgi'            => ['CS'],
    'email_templates.cgi'             => ['CS'],
    'send_emails.cgi'                 => ['CS'],

    'f_client_anonymization.cgi'     => ['Compliance'],
    'f_client_anonymization_dcc.cgi' => ['Compliance'],

    'download_document.cgi'       => ['CS', 'Compliance', 'Quants', 'IT'],
    'f_client_combined_audit.cgi' => ['CS', 'Compliance'],
    'f_dailyturnoverreport.cgi' => ['Accounts', 'Quants', 'IT'],
    'f_quant_query.cgi'         => ['Quants',   'CS'],
    'f_dynamic_settings.cgi'    => ['Quants',   'IT'],    # it has extra internal logic inside

    'f_save.cgi'                                                              => ['Quants'],
    'f_upload_holidays.cgi'                                                   => ['Quants'],
    'f_bet_iv.cgi'                                                            => ['Quants'],
    'f_bbdl_download.cgi'                                                     => ['Quants'],
    'f_bbdl_list_directory.cgi'                                               => ['Quants'],
    'f_bbdl_scheduled_request_files.cgi'                                      => ['Quants'],
    'f_bbdl_upload.cgi'                                                       => ['Quants'],
    'f_bbdl_upload_request_files.cgi'                                         => ['Quants'],
    'quant/market_data_mgmt/update_economic_events.cgi'                       => ['Quants'],
    'quant/market_data_mgmt/update_price_preview.cgi'                         => ['Quants'],
    'quant/market_data_mgmt/update_custom_commission.cgi'                     => ['Quants'],
    'quant/market_data_mgmt/update_tentative_events.cgi'                      => ['Quants'],
    'quant/market_data_mgmt/update_used_interest_rates.cgi'                   => ['Quants'],
    'quant/market_data_mgmt/update_volatilities/save_used_volatilities.cgi'   => ['Quants'],
    'quant/market_data_mgmt/update_volatilities/update_used_volatilities.cgi' => ['Quants'],
    'quant/market_data_mgmt/update_multiplier_config.cgi'                     => ['Quants'],
    'quant/pricing/bpot_graph_json.cgi'                                       => ['Quants'],
    'quant/risk_dashboard.cgi'                                                => ['Quants'],
    'quant/trading_strategy.cgi'                                              => ['Quants'],
    'quant/update_vol.cgi'                                                    => ['Quants'],
    'quant/validate_surface.cgi'                                              => ['Quants'],
    'quant/edit_interest_rate.cgi'                                            => ['Quants'],
    'quant/market_data_mgmt/quant_market_tools_backoffice.cgi'                => ['Quants'],
    'quant/pricing/bpot.cgi'                                                  => ['Quants'],
    'quant/pricing/f_dealer.cgi'                                              => ['Quants'],
    'quant/product_management.cgi'                                            => ['Quants'],
    'quant/settle_contracts.cgi'                                              => ['Quants'],
    'quant/quants_config.cgi'                                                 => ['Quants'],
    'quant/update_quants_config.cgi'                                          => ['Quants'],
    'quant/internal_transfer_fees.cgi'                                        => ['Quants'],
    'quant/client_limit.cgi'                                                  => ['Quants'],
};

sub init {
    $ENV{REQUEST_STARTTIME} = Time::HiRes::time;    ## no critic (RequireLocalizedPunctuationVars)
    $^T                     = time;                 ## no critic (RequireLocalizedPunctuationVars)
                                                    # Turn off any outstanding alarm, perhaps from a previous request in this mod_perl process,
                                                    # while we figure out how we might want to alarm on this particular request.
    alarm(0);
    build_request();

    if (BOM::Config::on_qa()) {
        # Sometimes it is needed to do some stuff on QA's backoffice with production databases (backpricing for Quants checking/etc)
        # here we implemenet an easy way of selection of needed database
        my $needed_service =
            BOM::Backoffice::Cookie::get_cookie('backprice') ? '/home/nobody/.pg_service_backprice.conf' : '/home/nobody/.pg_service.conf';

        #in case backprice settings have changed for session, make sure this fork uses newer pg_service file, but clearing Chronicle instance
        if (!$ENV{PGSERVICEFILE} || $needed_service ne $ENV{PGSERVICEFILE}) {
            BOM::Config::Chronicle::clear_connections();
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

        my $staff = BOM::Backoffice::Auth0::check_staff();
        @ENV{qw(AUDIT_STAFF_NAME AUDIT_STAFF_IP)} = ('unauthenticated', request()->client_ip);    ## no critic (RequireLocalizedPunctuationVars)
        $ENV{AUDIT_STAFF_NAME} = $staff->{nickname} if $staff;                                    ## no critic (RequireLocalizedPunctuationVars)

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
    my $staffname = 'unauthenticated';
    my $staff     = BOM::Backoffice::Auth0::check_staff();
    $staffname = $staff->{nickname} if $staff;
    my $s = $0;
    $s =~ s{^\Q/home/website/www}{};
    my $log = BOM::Backoffice::Config::config()->{log}->{staff};
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
    my $staff   = BOM::Backoffice::Auth0::check_staff();
    warn "_show_error_and_exit: $error (IP: " . request()->client_ip . '), user: ' . ($staff ? $staff->{nickname} : '-');
    # this can be duplicated for ALARM message, but not an issue
    PrintContentType();
    if ($staff) {
        # user is logged in, but access is not enabled;
        print qq~
            <div id="page_timeout_notice" class="aligncenter">
                <p class='normalfonterror'>$timenow $error</p>
                <a href="javascript:document.location.reload();">
                    <b>Reload page</b>
                </a>
            </div>~;
    } else {
        # user is not logged in, redirect him to login page
        BOM::Backoffice::Utility::redirect_login();
    }
    BOM::Backoffice::Request::request_completed();
    exit;
}

sub _check_access {
    my $script = shift // '';
    $script =~ s/^\///;
    # don't allow access to unknown scripts
    return 0 unless defined $permissions->{$script};
    return 1 if any { $_ eq 'ALL' } @{$permissions->{$script}};
    return BOM::Backoffice::Auth0::has_authorisation($permissions->{$script});
}

1;
