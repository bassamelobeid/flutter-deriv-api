package BOM::Backoffice::Sysinit;

use warnings;
use strict;

use File::Copy;
use Guard;
use List::MoreUtils qw( any );
use Path::Tiny;
use Plack::App::CGIBin::Streaming;
use Time::HiRes ();
use Log::Any    qw($log);

use BOM::Backoffice::Auth;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request localize);
use BOM::Backoffice::Request::Base;
use BOM::Config::Chronicle;
use BOM::Config;

=head1 NAME

BOM::Backoffice::Sysinit

=head1 DESCRIPTION

A module manages the requests and the permissions of the pages.

=cut

my $permissions = {
    'f_broker_login.cgi' => ['ALL'],
    'login.cgi'          => ['ALL'],
    'logout.cgi'         => ['ALL'],

    'batch_payments.cgi'             => ['Payments', 'AccountsLimited', 'AccountsAdmin'],
    'f_makedcc.cgi'                  => ['Payments', 'AccountsAdmin'],
    'f_makedcc_mt5_autotransfer.cgi' => ['Payments', 'Quants'],
    'f_manager.cgi'                  => ['Payments', 'AccountsLimited', 'AccountsAdmin', 'Quants'],
    'f_manager_confodeposit.cgi'     => ['Payments', 'AccountsLimited', 'AccountsAdmin'],
    'f_manager_crypto.cgi'           => ['Payments', 'AccountsLimited', 'AccountsAdmin'],
    'f_rescind_freegift.cgi'         => ['Payments'],
    'f_rescind_listofaccounts.cgi'   => ['Payments'],
    'f_manager_mt5_autotransfer.cgi' => ['Payments'],
    'crypto_admin.cgi'               => ['Crypto'],

    'monthly_client_report.cgi' => ['AccountsLimited', 'AccountsAdmin', 'Marketing'],
    'payments_report.cgi'       => ['AccountsLimited', 'AccountsAdmin', 'Marketing'],
    'f_accountingreports.cgi'   => ['AccountsLimited', 'AccountsAdmin', 'Marketing'],
    'aggregate_balance.cgi'     => ['AccountsLimited', 'AccountsAdmin', 'Marketing'],
    'f_upload_ewallet.cgi'      => ['AccountsLimited', 'AccountsAdmin', 'Marketing'],

    'promocode_edit.cgi'             => ['Marketing'],
    'f_promotional.cgi'              => ['Marketing'],
    'f_promotional_processing.cgi'   => ['Marketing'],
    'fetch_myaffiliate_payment.cgi'  => ['Marketing'],
    'f_app_management.cgi'           => ['Marketing'],
    'f_payment_agent_list.cgi'       => ['Marketing', 'Compliance', 'CS', 'MarketingReadOnly'],    # extra check in page
    'f_change_affiliates_token.cgi'  => ['Marketing'],
    'partners/change_partner_id.cgi' => ['Marketing'],
    'f_ib_affiliate.cgi'             => ['Marketing', 'MarketingReadOnly'],
    'f_client_bonus_check.cgi'       => ['Marketing'],
    'f_bulk_tagging.cgi'             => ['Marketing'],
    'update_affiliate_id.cgi'        => ['Marketing'],

    'c_listclientlimits.cgi'              => ['CS'],
    'client_email.cgi'                    => ['CS', 'AccountsLimited', 'AccountsAdmin'],
    'client_impersonate.cgi'              => ['CS', 'MarketingReadOnly'],
    'f_bo_enquiry.cgi'                    => ['CS'],
    'f_clientloginid.cgi'                 => ['CS', 'MarketingReadOnly', 'AccountsLimited', 'AccountsAdmin'],
    'f_clientloginid_edit.cgi'            => ['CS', 'MarketingReadOnly', 'AccountsLimited', 'AccountsAdmin'],
    'f_client_comments.cgi'               => ['CS', 'MarketingReadOnly'],
    'f_clientloginid_newpassword.cgi'     => ['CS'],
    'f_client_affiliate_details.cgi'      => ['CS', 'MarketingReadOnly'],
    'partners/client_partner_details.cgi' => ['CS', 'MarketingReadOnly'],
    'affiliate_reputation_details.cgi'    => ['CS', 'Compliance', 'MarketingReadOnly'],
    'f_send_statement.cgi'                => ['CS'],
    'f_investigative.cgi'                 => ['CS'],
    'f_makeclientdcc.cgi'                 => ['CS', 'AccountsLimited', 'AccountsAdmin'],
    'f_manager_history.cgi'               => ['CS', 'AccountsLimited', 'AccountsAdmin', 'MarketingReadOnly'],
    'f_statement_internal_transfer.cgi'   => ['CS'],
    'f_manager_crypto_history.cgi'        => ['CS', 'MarketingReadOnly', 'AccountsLimited', 'AccountsAdmin'],
    'f_manager_statement.cgi'             => ['CS', 'AccountsLimited',   'AccountsAdmin',   'MarketingReadOnly'],
    'f_popupclientsearch.cgi'             => ['CS', 'MarketingReadOnly'],
    'f_profit_check.cgi'                  => ['CS', 'MarketingReadOnly'],
    'f_profit_table.cgi'                  => ['CS'],
    'f_setting_paymentagent.cgi'          => ['CS'],
    'f_setting_selfexclusion.cgi'         => ['CS'],
    'f_viewclientsubset.cgi'              => ['CS'],
    'f_viewloginhistory.cgi'              => ['CS', 'MarketingReadOnly'],
    'ip_search.cgi'                       => ['CS', 'MarketingReadOnly'],
    'show_audit_trail.cgi'                => ['CS', 'AccountsLimited',   'AccountsAdmin'],
    'untrusted_client_edit.cgi'           => ['CS', 'MarketingReadOnly', 'AccountsLimited', 'AccountsAdmin'],
    'sync_client_status.cgi'              => ['CS'],
    'send_emails.cgi'                     => ['CS'],
    'fetch_client_details.cgi'            => ['CS'],
    'p2p_order_list.cgi'        => ['P2PRead', 'P2PWrite', 'P2PAdmin', 'AntiFraud'],
    'p2p_order_manage.cgi'      => ['P2PRead', 'P2PWrite', 'P2PAdmin', 'AntiFraud'],    # P2PRead is restricted from handling disputes in the page
    'p2p_advertiser_list.cgi'   => ['P2PRead', 'P2PWrite', 'P2PAdmin', 'AntiFraud', 'PaymentsAdmin'],    # Additional checks wihin page
    'p2p_advertiser_manage.cgi' => ['P2PRead', 'P2PWrite', 'P2PAdmin', 'AntiFraud', 'PaymentsAdmin', 'MarketingReadOnly'],    # same
    'p2p_dynamic_settings.cgi'                  => ['P2PAdmin',   'AntiFraud'],
    'p2p_payment_method_manage.cgi'             => ['P2PAdmin',   'AntiFraud'],
    'p2p_advert_rates_manage.cgi'               => ['P2PAdmin',   'AntiFraud'],
    'p2p_band_management.cgi'                   => ['P2PAdmin',   'AntiFraud'],
    'crypto_fraudulent_addresses.cgi'           => ['Compliance', 'Crypto'],
    'crypto_wrong_currency_deposit.cgi'         => ['CS',         'Crypto'],
    'crypto_credit_wrong_currency_deposits.cgi' => ['CS',         'Crypto'],

    'f_setting_website_status.cgi' => ['CSWrite'],

    'f_setting_selfexclusion_restricted.cgi'  => ['Compliance'],
    'f_client_anonymization.cgi'              => ['Compliance'],
    'f_client_anonymization_dcc.cgi'          => ['Compliance'],
    'f_client_anonymization_confirmation.cgi' => ['Compliance'],
    'bulk_aml_risk.cgi'                       => ['Compliance'],
    'f_client_bulk_authentication.cgi'        => ['Compliance',      'CS', 'Payments'],
    'f_client_combined_audit.cgi'             => ['CS',              'Compliance'],
    'f_dailyturnoverreport.cgi'               => ['AccountsLimited', 'AccountsAdmin', 'Quants', 'IT', 'Marketing'],
    'f_quant_query.cgi'                       => ['Quants',          'CS'],
    'f_dynamic_settings.cgi'                  => ['Quants',          'IT'],    # it has extra internal logic inside
    'f_resync_service.cgi'                    => ['Quants',          'IT'],
    'crypto_dynamic_settings.cgi'             => ['IT'],
    'f_idv_dashboard.cgi'                     => ['CS', 'Compliance', 'CostControl', 'IDV'],

    'f_internal_transfer.cgi' => ['PaymentInternalTransfer'],

    'f_save.cgi'                                                              => ['QuantsWrite', 'DealingWrite'],
    'f_upload_holidays.cgi'                                                   => ['QuantsWrite', 'DealingWrite'],
    'f_bet_iv.cgi'                                                            => ['Quants',      'DealingWrite'],
    'f_bbdl_download.cgi'                                                     => ['Quants',      'DealingWrite'],
    'f_bbdl_list_directory.cgi'                                               => ['Quants',      'DealingWrite'],
    'f_bbdl_scheduled_request_files.cgi'                                      => ['QuantsWrite', 'DealingWrite'],
    'f_bbdl_upload.cgi'                                                       => ['QuantsWrite', 'DealingWrite'],
    'f_bbdl_upload_request_files.cgi'                                         => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_economic_events.cgi'                       => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_price_preview.cgi'                         => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_commission.cgi'                            => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_custom_commission.cgi'                     => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_tentative_events.cgi'                      => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_used_interest_rates.cgi'                   => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_volatilities/save_used_volatilities.cgi'   => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_volatilities/update_used_volatilities.cgi' => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/update_economic_event_price_preview.cgi'          => ['Quants',      'DealingWrite'],
    'quant/market_data_mgmt/update_multiplier_config.cgi'                     => ['Quants',      'DealingWrite'],
    'quant/market_data_mgmt/update_accumulator_config.cgi'                    => ['Quants',      'DealingWrite'],
    'quant/market_data_mgmt/update_vanilla_config.cgi'                        => ['Quants',      'DealingWrite'],
    'quant/market_data_mgmt/update_turbos_config.cgi'                         => ['Quants',      'DealingWrite'],
    'quant/market_data_mgmt/update_feed_config.cgi'                           => ['Quants',      'DealingWrite'],
    'quant/pricing/bpot_graph_json.cgi'                                       => ['Quants',      'CS'],
    'quant/risk_dashboard.cgi'                                                => ['Quants',      'DealingWrite'],
    'quant/trading_strategy.cgi'                                              => ['Quants',      'DealingWrite'],
    'quant/update_vol.cgi'                                                    => ['Quants',      'DealingWrite'],
    'quant/validate_surface.cgi'                                              => ['Quants',      'DealingWrite'],
    'quant/edit_interest_rate.cgi'                                            => ['QuantsWrite', 'DealingWrite'],
    'quant/market_data_mgmt/quant_market_tools_backoffice.cgi'                => ['QuantsWrite', 'DealingWrite'],
    'quant/pricing/bpot.cgi'                                                  => ['Quants',      'CS'],
    'quant/pricing/f_dealer.cgi'                                              => ['QuantsWrite', 'DealingWrite'],
    'quant/product_management.cgi'                                            => ['Quants',      'DealingWrite'],
    'quant/settle_contracts.cgi'                                              => ['Quants',      'DealingWrite'],
    'quant/quants_config.cgi'                                                 => ['Quants',      'DealingWrite'],
    'quant/update_quants_config.cgi'                                          => ['QuantsWrite', 'DealingWrite'],
    'quant/client_limit.cgi'                                                  => ['Quants',      'DealingWrite'],
    'quant/multiplier_risk_management.cgi'                                    => ['Quants',      'DealingWrite'],
    'quant/accumulator_risk_management.cgi'                                   => ['Quants',      'DealingWrite'],
    'quant/vanilla_risk_management.cgi'                                       => ['Quants',      'DealingWrite'],
    'quant/turbos_risk_management.cgi'                                        => ['Quants',      'DealingWrite'],
    'quant/feed_configuration.cgi'                                            => ['Quants',      'DealingWrite'],
    'quants_createdcc.cgi'                                                    => ['QuantsWrite', 'DealingWrite'],
    'quant/commission_management.cgi'                                         => ['Quants',      'DealingWrite'],
    'quant/affiliate_payment_management.cgi'                                  => ['Quants',      'DealingWrite'],
    'doughflow_method_manage.cgi'                                             => ['IT',          'PaymentsAdmin'],
    'dividend_scheduler_tool.cgi'                                             => ['Quants',      'DealingWrite'],
    'quant/dividend_schedulers/new_dividend_scheduler.cgi'                    => ['Quants',      'DealingWrite'],
    'quant/dividend_schedulers/edit_dividend_scheduler.cgi'                   => ['Quants',      'DealingWrite'],
    'quant/dividend_schedulers/dividend_scheduler_controller.cgi'             => ['Quants',      'DealingWrite'],
    'quant/dividend_schedulers/index_dividend_scheduler.cgi'                  => ['Quants',      'DealingWrite'],
    'quant/cfd_account_management.cgi'                                        => ['Quants',      'DealingWrite', 'Compliance'],

    'payments_dynamic_settings.cgi'       => ['Payments', 'AntiFraud'],    # will have its own validation per setting
    'payments_dynamic_settings_dcc.cgi'   => ['Payments'],
    'payment_agents_dynamic_settings.cgi' => ['IT'],
    'payments_category_manage.cgi'        => ['Payments'],
    'dynamic_settings_audit_trail.cgi'    => ['ALL'],                      # will have its own validation per setting

    'quant/callputspread_barrier_multiplier/index_callputspread_barrier_multiplier.cgi'      => ['Quants',     'DealingWrite'],
    'quant/callputspread_barrier_multiplier/callputspread_barrier_multiplier_controller.cgi' => ['Quants',     'DealingWrite'],
    'compliance_dashboard.cgi'                                                               => ['Compliance', 'IT'],
    'payment_agent_tier_manage.cgi'                                                          => ['Compliance'],
    'wallet_migration.cgi'                                                                   => ['CS'],
    'mt5_bulk_deposit.cgi'                                                                   => ['Quants'],
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

        $SIG{ALRM} = sub {    ## no critic (RequireLocalizedPunctuationVars)
            my $runtime = time - $^T;

            $log->warn("Panic timeout after $runtime seconds");
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

        my $staff = BOM::Backoffice::Auth::check_staff();
        @ENV{qw(AUDIT_STAFF_NAME AUDIT_STAFF_IP)} = ('unauthenticated', request()->client_ip);    ## no critic (RequireLocalizedPunctuationVars)
        $ENV{AUDIT_STAFF_NAME} = $staff->{nickname} if $staff;                                    ## no critic (RequireLocalizedPunctuationVars)

        request()->http_handler($http_handler);

        _show_error_and_exit('Access to ' . $http_handler->script_name . ' is not allowed') unless authorise($http_handler->script_name);
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
        $CGI::POST_MAX        = 20 * 1024 * 1024;    # max 20MB posts
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
    my $staff     = BOM::Backoffice::Auth::check_staff();
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
    my $staff   = BOM::Backoffice::Auth::check_staff();
    $log->warn("_show_error_and_exit: $error (IP: " . request()->client_ip . '), user: ' . ($staff ? $staff->{nickname} : '-'));
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

sub authorise {
    my $script = shift // '';
    $script =~ s/^\///;

    # don't allow access to unknown scripts
    return 0 unless defined $permissions->{$script};
    return 1 if any { $_ eq 'ALL' } @{$permissions->{$script}};
    return BOM::Backoffice::Auth::has_authorisation($permissions->{$script});
}

1;
