package BOM::Event::Process;

use strict;
use warnings;

no indirect;

use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Log::Any qw($log);

use BOM::Event::Actions::Client;
use BOM::Event::Actions::CustomerStatement;
use BOM::Event::Actions::MT5;
use BOM::Event::Actions::CTrader;
use BOM::Event::Actions::DerivEZ;
use BOM::Event::Actions::Client::DisputeNotification;
use BOM::Event::Actions::Client::IdentityVerification;
use BOM::Event::Actions::Client::Status;
use BOM::Event::Actions::CryptoCashier;
use BOM::Event::Actions::Anonymization;
use BOM::Event::Actions::Email;
use BOM::Event::Actions::P2P;
use BOM::Event::Actions::MyAffiliate;
use BOM::Event::Actions::User;
use BOM::Event::Actions::Wallets;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::App;
use BOM::Event::Utility qw(exception_logged);
use BOM::Event::Actions::Authentication;
use BOM::Event::Services::Track;
use BOM::Event::Actions::Common;
use BOM::Event::Actions::External;

use Scalar::Util qw(blessed);

=head1 NAME

BOM::Event::Process - Process events

=head1 SYNOPSIS

    my $obj = BOM::Event::Process::process(type => 'generic');
    $obj->process($event, $stream);

=head1 DESCRIPTION

This class responsibility is to process events. It has action to method mapping for each job category.
Based on type of event its associated method is invoked.

=cut

my $action_mapping = {
    generic => {
        email_statement                             => \&BOM::Event::Actions::CustomerStatement::email_statement,
        sync_user_to_MT5                            => \&BOM::Event::Actions::MT5::sync_info,
        store_mt5_transaction                       => \&BOM::Event::Actions::MT5::redis_record_mt5_transfer,
        new_mt5_signup                              => \&BOM::Event::Actions::MT5::new_mt5_signup,
        signup                                      => \&BOM::Event::Actions::Client::signup,
        mt5_inactive_account_closure_report         => \&BOM::Event::Actions::MT5::mt5_inactive_account_closure_report,
        anonymize_client                            => \&BOM::Event::Actions::Anonymization::anonymize_client,
        bulk_anonymization                          => \&BOM::Event::Actions::Anonymization::bulk_anonymization,
        anonymize_clients                           => \&BOM::Event::Actions::Anonymization::anonymize_clients,
        bulk_client_status_update                   => \&BOM::Event::Actions::Client::bulk_client_status_update,
        auto_anonymize_candidates                   => \&BOM::Event::Actions::Anonymization::auto_anonymize_candidates,
        document_upload                             => \&BOM::Event::Actions::Client::document_upload,
        ready_for_authentication                    => \&BOM::Event::Actions::Client::ready_for_authentication,
        client_verification                         => \&BOM::Event::Actions::Client::client_verification,
        onfido_doc_ready_for_upload                 => \&BOM::Event::Actions::Client::onfido_doc_ready_for_upload,
        verify_address                              => \&BOM::Event::Actions::Client::verify_address,
        profile_change                              => \&BOM::Event::Actions::User::profile_change,
        social_responsibility_check                 => \&BOM::Event::Actions::Client::social_responsibility_check,
        aml_high_risk_updated                       => \&BOM::Event::Actions::Client::aml_high_risk_updated,
        sync_onfido_details                         => \&BOM::Event::Actions::Client::sync_onfido_details,
        qualifying_payment_check                    => \&BOM::Event::Actions::Client::qualifying_payment_check,
        payment_deposit                             => \&BOM::Event::Actions::Client::payment_deposit,
        send_email                                  => \&BOM::Event::Actions::Email::send_email_generic,
        affiliate_sync_initiated                    => \&BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated,
        payops_event_update_account_status          => \&BOM::Event::Actions::Client::payops_event_update_account_status,
        payops_event_request_poo                    => \&BOM::Event::Actions::Client::payops_event_request_poo,
        withdrawal_limit_reached                    => \&BOM::Event::Actions::Client::withdrawal_limit_reached,
        p2p_advert_updated                          => \&BOM::Event::Actions::P2P::advert_updated,
        p2p_order_created                           => \&BOM::Event::Actions::P2P::order_created,
        p2p_order_updated                           => \&BOM::Event::Actions::P2P::order_updated,
        p2p_order_expired                           => \&BOM::Event::Actions::P2P::order_expired,
        p2p_order_chat_create                       => \&BOM::Event::Actions::P2P::order_chat_create,
        p2p_advertiser_created                      => \&BOM::Event::Actions::P2P::advertiser_created,
        p2p_advertiser_updated                      => \&BOM::Event::Actions::P2P::advertiser_updated,
        p2p_advert_orders_updated                   => \&BOM::Event::Actions::P2P::p2p_advert_orders_updated,
        p2p_advertiser_online_status                => \&BOM::Event::Actions::P2P::advertiser_online_status,
        p2p_chat_received                           => \&BOM::Event::Actions::P2P::chat_received,
        p2p_timeout_refund                          => \&BOM::Event::Actions::P2P::timeout_refund,
        p2p_dispute_expired                         => \&BOM::Event::Actions::P2P::dispute_expired,
        p2p_settings_updated                        => \&BOM::Event::Actions::P2P::settings_updated,
        crypto_withdrawal                           => \&BOM::Event::Actions::Client::handle_crypto_withdrawal,
        client_promo_codes_upload                   => \&BOM::Event::Actions::Client::client_promo_codes_upload,
        shared_payment_method_found                 => \&BOM::Event::Actions::Client::shared_payment_method_found,
        verify_false_profile_info                   => \&BOM::Event::Actions::User::verify_false_profile_info,
        dispute_notification                        => \&BOM::Event::Actions::Client::DisputeNotification::dispute_notification,
        account_reactivated                         => \&BOM::Event::Actions::Client::account_reactivated,
        identity_verification_requested             => \&BOM::Event::Actions::Client::IdentityVerification::verify_identity,
        identity_verification_processed             => \&BOM::Event::Actions::Client::IdentityVerification::verify_process,
        poi_check_rules                             => \&BOM::Event::Actions::Client::poi_check_rules,
        check_name_changes_after_first_deposit      => \&BOM::Event::Actions::Client::check_name_changes_after_first_deposit,
        bulk_authentication                         => \&BOM::Event::Actions::Authentication::bulk_authentication,
        p2p_adverts_updated                         => \&BOM::Event::Actions::P2P::p2p_adverts_updated,
        affiliate_loginids_sync                     => \&BOM::Event::Actions::MyAffiliate::affiliate_loginids_sync,
        p2p_advertiser_approval_changed             => \&BOM::Event::Actions::P2P::p2p_advertiser_approval_changed,
        cms_add_affiliate_client                    => \&BOM::Event::Actions::Client::link_affiliate_client,
        df_anonymization_done                       => \&BOM::Event::Actions::Anonymization::df_anonymization_done,
        mt5_archived_account_reset_trading_password => \&BOM::Event::Actions::MT5::mt5_archived_account_reset_trading_password,
        account_verification_for_pending_payout     => \&BOM::Event::Services::Track::account_verification_for_pending_payout,
        trigger_cio_broadcast                       => \&BOM::Event::Actions::Common::trigger_cio_broadcast,
        mt5_deriv_auto_rescind                      => \&BOM::Event::Actions::MT5::mt5_deriv_auto_rescind,
        crypto_cashier_transaction_updated          => \&BOM::Event::Actions::CryptoCashier::crypto_cashier_transaction_updated,
        sideoffice_set_account_status               => \&BOM::Event::Actions::Client::Status::execute_set_status,
        sideoffice_remove_account_status            => \&BOM::Event::Actions::Client::Status::execute_remove_status,
        update_loginid_status                       => \&BOM::Event::Actions::MT5::update_loginid_status,
        bulk_affiliate_loginids_sync                => \&BOM::Event::Actions::MyAffiliate::bulk_affiliate_loginids_sync,
        p2p_update_local_currencies                 => \&BOM::Event::Actions::P2P::update_local_currencies,
        idv_webhook_received                        => \&BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay,
        sync_mt5_accounts_status                    => \&BOM::Event::Actions::MT5::sync_mt5_accounts_status,
        mt5_archive_restore_sync                    => \&BOM::Event::Actions::MT5::mt5_archive_restore_sync,
        mt5_archive_accounts                        => \&BOM::Event::Actions::MT5::mt5_archive_accounts,
        poa_updated                                 => \&BOM::Event::Actions::Client::poa_updated,
        poi_updated                                 => \&BOM::Event::Actions::Client::poi_updated,
        notify_resubmission_of_poi_poa_documents    => \&BOM::Event::Actions::Client::notify_resubmission_of_poi_poa_documents,
        ctrader_account_created                     => \&BOM::Event::Actions::CTrader::ctrader_account_created,
        underage_client_detected                    => \&BOM::Event::Actions::Client::underage_client_detected,
        poi_claim_ownership                         => \&BOM::Event::Actions::Client::poi_claim_ownership,
        onfido_check_completed                      => \&BOM::Event::Actions::Client::onfido_check_completed,
        mt5_svg_migration_requested                 => \&BOM::Event::Actions::MT5::mt5_svg_migration_requested,
        nodejs_hello                                => \&BOM::Event::Actions::External::nodejs_hello,
        withdrawal_estimated_fee_updated            => \&BOM::Event::Actions::CryptoCashier::withdrawal_estimated_fee_updated,
        recheck_onfido_face_similarity              => \&BOM::Event::Actions::Client::recheck_onfido_face_similarity,
    },
    track => {
        app_deleted                                      => \&BOM::Event::Actions::App::app_deleted,
        app_registered                                   => \&BOM::Event::Actions::App::app_registered,
        app_updated                                      => \&BOM::Event::Actions::App::app_updated,
        email_subscription                               => \&BOM::Event::Actions::App::email_subscription,
        account_opening_new                              => \&BOM::Event::Actions::Client::account_opening_new,
        account_verification                             => \&BOM::Event::Actions::Client::account_verification,
        account_closure                                  => \&BOM::Event::Actions::Client::track_account_closure,
        account_reactivated                              => \&BOM::Event::Actions::Client::track_account_reactivated,
        api_token_created                                => \&BOM::Event::Actions::Client::api_token_created,
        api_token_deleted                                => \&BOM::Event::Actions::Client::api_token_deleted,
        confirm_change_email                             => \&BOM::Event::Actions::Client::confirm_change_email,
        crypto_deposit_email                             => \&BOM::Event::Actions::Client::crypto_deposit_email,
        crypto_withdrawal_email                          => \&BOM::Event::Actions::Client::crypto_withdrawal_email,
        crypto_withdrawal_rejected_email_v2              => \&BOM::Event::Actions::Client::crypto_withdrawal_rejected_email_v2,
        payment_deposit                                  => \&BOM::Event::Actions::Client::track_payment_deposit,
        payment_withdrawal                               => \&BOM::Event::Actions::Client::payment_withdrawal,
        payment_withdrawal_reversal                      => \&BOM::Event::Actions::Client::payment_withdrawal_reversal,
        request_change_email                             => \&BOM::Event::Actions::Client::request_change_email,
        request_edd_document_upload                      => \&BOM::Event::Actions::Client::request_edd_document_upload,
        reset_password_confirmation                      => \&BOM::Event::Actions::Client::reset_password_confirmation,
        reset_password_request                           => \&BOM::Event::Actions::Client::reset_password_request,
        set_financial_assessment                         => \&BOM::Event::Actions::Client::set_financial_assessment,
        signup                                           => \&BOM::Event::Actions::Client::track_signup,
        transfer_between_accounts                        => \&BOM::Event::Actions::Client::transfer_between_accounts,
        trading_platform_account_created                 => \&BOM::Event::Actions::Client::trading_platform_account_created,
        trading_platform_password_reset_request          => \&BOM::Event::Actions::Client::trading_platform_password_reset_request,
        trading_platform_investor_password_reset_request => \&BOM::Event::Actions::Client::trading_platform_investor_password_reset_request,
        trading_platform_password_changed                => \&BOM::Event::Actions::Client::trading_platform_password_changed,
        trading_platform_password_change_failed          => \&BOM::Event::Actions::Client::trading_platform_password_change_failed,
        trading_platform_investor_password_changed       => \&BOM::Event::Actions::Client::trading_platform_investor_password_changed,
        trading_platform_investor_password_change_failed => \&BOM::Event::Actions::Client::trading_platform_investor_password_change_failed,
        verify_change_email                              => \&BOM::Event::Actions::Client::verify_change_email,
        derivx_account_deactivated                       => \&BOM::Event::Actions::Client::derivx_account_deactivated,
        professional_status_requested                    => \&BOM::Event::Actions::Client::professional_status_requested,
        payops_event_email                               => \&BOM::Event::Actions::Client::payops_event_email,
        mt5_inactive_account_closed                      => \&BOM::Event::Actions::MT5::mt5_inactive_account_closed,
        mt5_inactive_notification                        => \&BOM::Event::Actions::MT5::mt5_inactive_notification,
        mt5_change_color                                 => \&BOM::Event::Actions::MT5::mt5_change_color,
        mt5_password_changed                             => \&BOM::Event::Actions::MT5::mt5_password_changed,
        p2p_advert_created                               => \&BOM::Event::Actions::P2P::advert_created,
        p2p_advertiser_cancel_at_fault                   => \&BOM::Event::Actions::P2P::advertiser_cancel_at_fault,
        p2p_advertiser_temp_banned                       => \&BOM::Event::Actions::P2P::advertiser_temp_banned,
        p2p_archived_ad                                  => \&BOM::Event::Actions::P2P::archived_ad,
        login                                            => \&BOM::Event::Actions::User::login,
        profile_change                                   => \&BOM::Event::Actions::User::track_profile_change,
        underage_account_closed                          => \&BOM::Event::Services::Track::underage_account_closed,
        account_with_false_info_locked                   => \&BOM::Event::Services::Track::account_with_false_info_locked,
        multiplier_hit_type                              => \&BOM::Event::Services::Track::multiplier_hit_type,
        multiplier_near_expire_notification              => \&BOM::Event::Services::Track::multiplier_near_expire_notification,
        multiplier_near_dc_notification                  => \&BOM::Event::Services::Track::multiplier_near_dc_notification,
        age_verified                                     => \&BOM::Event::Services::Track::age_verified,
        poa_verification_warning                         => \&BOM::Event::Services::Track::poa_verification_warning,
        poa_verification_expired                         => \&BOM::Event::Services::Track::poa_verification_expired,
        poa_verification_failed_reminder                 => \&BOM::Event::Services::Track::poa_verification_failed_reminder,
        bonus_approve                                    => \&BOM::Event::Services::Track::bonus_approve,
        bonus_reject                                     => \&BOM::Event::Services::Track::bonus_reject,
        p2p_order_confirm_verify                         => \&BOM::Event::Services::Track::p2p_order_confirm_verify,
        p2p_limit_changed                                => \&BOM::Event::Services::Track::p2p_limit_changed,
        p2p_limit_upgrade_available                      => \&BOM::Event::Services::Track::p2p_limit_upgrade_available,
        poi_poa_resubmission                             => \&BOM::Event::Services::Track::poi_poa_resubmission,
        verify_email_closed_account_reset_password       => \&BOM::Event::Actions::Client::verify_email_closed_account_reset_password,
        verify_email_closed_account_account_opening      => \&BOM::Event::Actions::Client::verify_email_closed_account_account_opening,
        verify_email_closed_account_other                => \&BOM::Event::Actions::Client::verify_email_closed_account_other,
        request_payment_withdraw                         => \&BOM::Event::Actions::Client::request_payment_withdraw,
        account_opening_existing                         => \&BOM::Event::Actions::Client::account_opening_existing,
        self_tagging_affiliates                          => \&BOM::Event::Actions::Client::self_tagging_affiliates,
        authenticated_with_scans                         => \&BOM::Event::Actions::Client::authenticated_with_scans,
        document_uploaded                                => \&BOM::Event::Services::Track::document_upload,
        new_mt5_signup_stored                            => \&BOM::Event::Services::Track::new_mt5_signup,
        identity_verification_rejected                   => \&BOM::Event::Services::Track::identity_verification_rejected,
        p2p_advertiser_approved                          => \&BOM::Event::Services::Track::p2p_advertiser_approved,
        p2p_order_updated_handled                        => \&BOM::Event::Actions::P2P::track_p2p_order_event,
        risk_disclaimer_resubmission                     => \&BOM::Event::Actions::Email::send_client_email_track_event,
        unknown_login                                    => \&BOM::Event::Actions::Email::send_client_email_track_event,
        dp_successful_login                              => \&BOM::Event::Services::Track::dp_successful_login,
        pa_first_time_approved                           => \&BOM::Event::Services::Track::pa_first_time_approved,
        document_expiring_soon                           => \&BOM::Event::Services::Track::document_expiring_soon,
        document_expiring_today                          => \&BOM::Event::Services::Track::document_expiring_today,
        pa_transfer_confirm                              => \&BOM::Event::Actions::Client::pa_transfer_confirm,
        pa_withdraw_confirm                              => \&BOM::Event::Actions::Client::pa_withdraw_confirm,
        shared_payment_method_email_notification         => \&BOM::Event::Actions::Client::shared_payment_method_email_notification,
        derivez_inactive_account_closed                  => \&BOM::Event::Actions::DerivEZ::derivez_inactive_account_closed,
        derivez_inactive_notification                    => \&BOM::Event::Actions::DerivEZ::derivez_inactive_notification,
        duplicated_document_account_closed               => \&BOM::Event::Services::Track::duplicated_document_account_closed,

    },
    mt5_retryable => {
        link_myaff_token_to_mt5 => \&BOM::Event::Actions::MT5::link_myaff_token_to_mt5,
        mt5_deposit_retry       => \&BOM::Event::Actions::MT5::mt5_deposit_retry,
    },
    generic_retryable => {
        wallet_migration_started => \&BOM::Event::Actions::Wallets::wallet_migration_started,
    }};

=head1 METHODS

=head2 get_action_mappings

Returns available action mappings

=cut

sub get_action_mappings {
    return $action_mapping;
}

=head2 new

Required parameters

=over 4

=item * cateagory : type of jobs to process

=back

=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 actions

Returns available action mappings

=cut

sub actions {
    my $self = shift;

    return $action_mapping->{$self->{category}};
}

=head2 process

Process event passed by invoking corresponding method from action mapping

=head3 Required parameters

=over 4

=item * event_to_be_processed : emitted event ( {type => action, details => {}, context => {}})

=item * stream : stream or queue the event came from

=back

=cut

sub process {
    my ($self, $event, $stream) = @_;

    # event is of form { type => action, details => {}, context => {} }
    my $event_type = $event->{type} // '<unknown>';

    # don't process if type is not supported as of now
    unless (exists $self->actions->{$event_type}) {
        $log->debugf("ignoring event %s from stream %s", $event_type, $stream);
        return undef;
    }

    unless (exists $event->{details}) {
        $log->warnf("event %s from stream %s contains no details", $event_type, $stream);
        return undef;
    }

    my $context_info = $event->{context} // {};
    my @req_args     = map { $_ => $context_info->{$_} } grep { $context_info->{$_} } qw(brand_name language app_id);
    my $req          = BOM::Platform::Context::Request->new(@req_args);
    request($req);

    my $response = 0;
    try {
        $log->debugf("processing event %s from stream %s", $event_type, $stream);
        $response = $self->actions->{$event_type}->($event->{details});
        $response->retain if blessed($response) and $response->isa('Future');
    } catch ($e) {
        $log->errorf("An error occurred processing %s: %s", $event_type, $e);
        exception_logged();
    }

    return $response;
}

1;
