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
use BOM::Event::Actions::Client;
use BOM::Event::Actions::CryptoSubscription;
use BOM::Event::Actions::Anonymization;
use BOM::Event::Actions::Email;
use BOM::Event::Actions::P2P;
use BOM::Event::Actions::MyAffiliate;
use BOM::Event::Actions::User;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::App;
use BOM::Event::Utility qw(exception_logged);

use Scalar::Util qw(blessed);

=head1 NAME

BOM::Event::Process - Process events

=head1 SYNOPSIS

    BOM::Event::Process::process($event_to_be_processed)

=head1 DESCRIPTION

This class responsibility is to process events. It has action to method mapping.
Based on type of event its associated method is invoked.

=cut

my $action_mapping = {
    email_statement             => \&BOM::Event::Actions::CustomerStatement::email_statement,
    sync_user_to_MT5            => \&BOM::Event::Actions::MT5::sync_info,
    store_mt5_transaction       => \&BOM::Event::Actions::MT5::redis_record_mt5_transfer,
    new_mt5_signup              => \&BOM::Event::Actions::MT5::new_mt5_signup,
    mt5_password_changed        => \&BOM::Event::Actions::MT5::mt5_password_changed,
    anonymize_client            => \&BOM::Event::Actions::Anonymization::anonymize_client,
    bulk_anonymization          => \&BOM::Event::Actions::Anonymization::bulk_anonymization,
    document_upload             => \&BOM::Event::Actions::Client::document_upload,
    ready_for_authentication    => \&BOM::Event::Actions::Client::ready_for_authentication,
    client_verification         => \&BOM::Event::Actions::Client::client_verification,
    onfido_doc_ready_for_upload => \&BOM::Event::Actions::Client::onfido_doc_ready_for_upload,
    verify_address              => \&BOM::Event::Actions::Client::verify_address,
    profile_change              => \&BOM::Event::Actions::User::profile_change,
    login                       => \&BOM::Event::Actions::User::login,
    signup                      => \&BOM::Event::Actions::Client::signup,
    transfer_between_accounts   => \&BOM::Event::Actions::Client::transfer_between_accounts,
    account_closure             => \&BOM::Event::Actions::Client::account_closure,
    social_responsibility_check => \&BOM::Event::Actions::Client::social_responsibility_check,
    crypto_subscription         => \&BOM::Event::Actions::CryptoSubscription::subscription,
    new_crypto_address          => \&BOM::Event::Actions::CryptoSubscription::new_crypto_address,
    sync_onfido_details         => \&BOM::Event::Actions::Client::sync_onfido_details,
    authenticated_with_scans    => \&BOM::Event::Actions::Client::email_client_account_verification,
    qualifying_payment_check    => \&BOM::Event::Actions::Client::qualifying_payment_check,
    payment_deposit             => \&BOM::Event::Actions::Client::payment_deposit,
    send_email                  => \&BOM::Event::Actions::Email::send_email_generic,
    affiliate_sync_initiated    => \&BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated,
    withdrawal_limit_reached    => \&BOM::Event::Actions::Client::withdrawal_limit_reached,
    p2p_advert_created          => \&BOM::Event::Actions::P2P::advert_created,
    p2p_advert_updated          => \&BOM::Event::Actions::P2P::advert_updated,
    p2p_order_created           => \&BOM::Event::Actions::P2P::order_created,
    p2p_order_updated           => \&BOM::Event::Actions::P2P::order_updated,
    p2p_order_expired           => \&BOM::Event::Actions::P2P::order_expired,
    p2p_advertiser_created      => \&BOM::Event::Actions::P2P::advertiser_created,
    p2p_advertiser_updated      => \&BOM::Event::Actions::P2P::advertiser_updated,
    p2p_chat_received           => \&BOM::Event::Actions::P2P::chat_received,
    p2p_timeout_refund          => \&BOM::Event::Actions::P2P::timeout_refund,
    p2p_dispute_expired         => \&BOM::Event::Actions::P2P::dispute_expired,
    api_token_created           => \&BOM::Event::Actions::Client::api_token_created,
    api_token_deleted           => \&BOM::Event::Actions::Client::api_token_deleted,
    app_registered              => \&BOM::Event::Actions::App::app_registered,
    app_updated                 => \&BOM::Event::Actions::App::app_updated,
    app_deleted                 => \&BOM::Event::Actions::App::app_deleted,
    set_financial_assessment    => \&BOM::Event::Actions::Client::set_financial_assessment,
    aml_client_status_update    => \&BOM::Event::Actions::Client::aml_client_status_update,
    self_exclude                => \&BOM::Event::Actions::App::self_exclude,
    crypto_withdrawal           => \&BOM::Event::Actions::Client::handle_crypto_withdrawal,
    client_promo_codes_upload   => \&BOM::Event::Actions::Client::client_promo_codes_upload,
    shared_payment_method_found => \&BOM::Event::Actions::Client::shared_payment_method_found,
};

=head1 METHODS

=head2 get_action_mappings

Returns available action mappings

=cut

sub get_action_mappings {
    return $action_mapping;
}

=head2 process

Process event passed by invoking corresponding method from action mapping

=head3 Required parameters

=over 4

=item * event_to_be_processed : emitted event ( {type => action, details => {}, context => {}}, $queue_name )

=back

=cut

sub process {
    # event is of form { type => action, details => {}, context => {} }

    my $event_to_be_processed = shift;
    my $queue_name            = shift;

    my $event_type = $event_to_be_processed->{type} // '<unknown>';

    # don't process if type is not supported as of now
    unless (exists get_action_mappings()->{$event_type}) {
        $log->warnf("no function mapping found for event %s from queue %s", $event_type, $queue_name);
        return undef;
    }

    unless (exists $event_to_be_processed->{details}) {
        $log->warnf("event %s from queue %s contains no details", $event_type, $queue_name);
        return undef;
    }

    my $context_info = $event_to_be_processed->{context} // {};
    my @req_args     = map { $_ => $context_info->{$_} } grep { $context_info->{$_} } qw(brand_name language app_id);
    my $req          = BOM::Platform::Context::Request->new(@req_args);
    request($req);

    my $response = 0;
    try {
        $response = get_action_mappings()->{$event_type}->($event_to_be_processed->{details});
        $response->retain if blessed($response) and $response->isa('Future');
    } catch {
        my $e = $@;
        $log->errorf("An error occurred processing %s: %s", $event_type, $e);
        exception_logged();
    }

    return $response;
}

1;
