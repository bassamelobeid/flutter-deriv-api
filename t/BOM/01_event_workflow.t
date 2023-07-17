use strict;
use warnings;

use Log::Any::Test;
use Log::Any qw($log);

use Test::Fatal;
use Test::MockModule;
use Test::More;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Platform::Event::Emitter;
use BOM::Event::Process;
use BOM::Platform::Context;

initialize_events_redis();

use constant QUEUE_NAME => 'GENERIC_EVENTS_STREAM';

my $count  = 0;
my @events = ({
        'signup' => {
            loginid => 'CR121',
            email   => 'abc1@binary.com'
        }
    },
    {
        'signup' => {
            loginid => 'CR122',
            email   => 'abc2@binary.com'
        }
    },
    {
        'signup' => {
            loginid => 'CR123',
            email   => 'abc3@binary.com'
        }
    },
    {
        'signup' => {
            loginid => 'CR124',
            email   => 'abc4@binary.com'
        }
    },
    {
        'signup' => {
            loginid => 'CR125',
            email   => 'abc5@binary.com'
        }
    },
    {
        'signup' => {
            loginid => 'CR126',
            email   => 'abc6@binary.com'
        }
    },
    {
        'profile_change' => {
            loginid       => 'CR121',
            email_consent => 1
        }
    },
    {
        'profile_change' => {
            loginid       => 'CR122',
            email_consent => 0
        }
    },
    {
        'profile_change' => {
            loginid       => 'CR123',
            email_consent => 1
        }
    },
    {
        'anonymize_client' => {
            loginid => 'CR124',
        }});

subtest 'emit' => sub {
    like(
        exception {
            BOM::Platform::Event::Emitter::emit();
        },
        qr/Missing required parameter: type./,
        'missing action parameter',
    );

    like(
        exception {
            BOM::Platform::Event::Emitter::emit('dummy');
        },
        qr/Missing required parameter: data./,
        'missing data parameter',
    );

    is BOM::Platform::Event::Emitter::get(QUEUE_NAME), undef, 'No event is present so it should return undef';

    foreach my $event (@events) {
        my $action = (keys %$event)[0];
        $count = BOM::Platform::Event::Emitter::emit($action, $event->{$action});
    }

};

subtest 'process - generic jobs' => sub {
    my $proc            = BOM::Event::Process->new(category => 'generic');
    my $action_mappings = $proc->actions;

    cmp_deeply(
        [keys %$action_mappings],
        bag(
            qw/email_statement sync_user_to_MT5
                store_mt5_transaction new_mt5_signup anonymize_client bulk_anonymization auto_anonymize_candidates
                document_upload ready_for_authentication client_verification
                verify_address social_responsibility_check sync_onfido_details
                qualifying_payment_check
                payment_deposit send_email
                signup profile_change
                p2p_advertiser_created p2p_advertiser_updated
                p2p_advert_updated
                p2p_order_created p2p_order_updated p2p_order_expired p2p_order_chat_create
                p2p_timeout_refund p2p_dispute_expired p2p_chat_received
                affiliate_sync_initiated withdrawal_limit_reached payops_event_update_account_status payops_event_request_poo
                crypto_withdrawal idv_webhook_received
                client_promo_codes_upload onfido_doc_ready_for_upload shared_payment_method_found
                dispute_notification account_reactivated verify_false_profile_info check_onfido_rules mt5_archived_account_reset_trading_password
                identity_verification_requested identity_verification_processed
                mt5_inactive_account_closure_report bulk_authentication
                check_name_changes_after_first_deposit p2p_adverts_updated
                affiliate_loginids_sync p2p_advertiser_approval_changed p2p_advertiser_online_status p2p_advert_orders_updated
                cms_add_affiliate_client df_anonymization_done sideoffice_set_account_status sideoffice_remove_account_status
                account_verification_for_pending_payout bulk_client_status_update
                trigger_cio_broadcast crypto_cashier_transaction_updated
                update_loginid_status bulk_affiliate_loginids_sync p2p_update_local_currencies mt5_deriv_auto_rescind mt5_archive_restore_sync sync_mt5_accounts_status
                poa_updated underage_client_detected mt5_archive_accounts/
        ),
        'Correct number of actions that can be emitted'
    );

    is(ref($action_mappings->{$_}), 'CODE', 'event handler is a code reference') for keys %$action_mappings;

    $proc->process({}, 'my_stream');
    $log->contains_ok(qr/ignoring event <unknown> from stream my_stream/, 'Empty message not processed');

    $proc->process({type => 'dummy_action'}, QUEUE_NAME);
    $log->contains_ok(qr/ignoring event dummy_action from stream GENERIC_EVENTS_STREAM/,
        'Process cannot be processed as function action is not available');

    my $mock_process = Test::MockModule->new('BOM::Event::Process');
    $mock_process->redefine(
        'actions' => sub {
            return {
                signup          => sub { return 'Details registered'; },
                profile_change  => sub { return 'Unsubscribe flag updated'; },
                email_statement => sub { return 'Statement has been sent'; }
            };
        });

    is $proc->process({
            type    => 'signup',
            details => {}
        },
        QUEUE_NAME
        ),
        'Details registered', 'Invoked associated sub for signup event';

    is $proc->process({
            type    => 'profile_change',
            details => {}
        },
        QUEUE_NAME
        ),
        'Unsubscribe flag updated', 'Invoked associated sub for profile_change event';

    is $proc->process({
            type    => 'email_statement',
            details => {}
        },
        QUEUE_NAME
        ),
        'Statement has been sent', 'Invoked associated sub for email_statement event';

    $mock_process->redefine(
        'actions' => sub {
            return {
                signup          => sub { die 'Error - connection error'; },
                profile_change  => sub { die 'Error - connection error'; },
                email_statement => sub { die 'Error - connection error'; },
            };
        });

    is $proc->process({
            type    => 'signup',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    is $proc->process({
            type    => 'profile_change',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    is $proc->process({
            type    => 'email_statement',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';
};

subtest 'process - tracking jobs' => sub {
    my $proc            = BOM::Event::Process->new(category => 'track');
    my $action_mappings = $proc->actions;

    cmp_deeply(
        [keys %$action_mappings],
        bag(
            qw/multiplier_hit_type multiplier_near_expire_notification multiplier_near_dc_notification
                crypto_withdrawal_rejected_email_v2 crypto_withdrawal_email crypto_deposit_email
                api_token_created api_token_deleted app_registered app_updated app_deleted
                mt5_password_changed mt5_inactive_notification mt5_inactive_account_closed payops_event_email
                p2p_archived_ad p2p_advert_created p2p_advertiser_cancel_at_fault p2p_advertiser_temp_banned
                payment_withdrawal payment_withdrawal_reversal reset_password_request reset_password_confirmation
                request_change_email confirm_change_email verify_change_email account_reactivated
                login transfer_between_accounts set_financial_assessment payment_deposit
                account_closure profile_change account_opening_new trading_platform_account_created
                trading_platform_password_reset_request trading_platform_investor_password_reset_request
                trading_platform_password_changed trading_platform_password_change_failed
                trading_platform_investor_password_changed trading_platform_investor_password_change_failed
                underage_account_closed account_with_false_info_locked email_subscription signup
                age_verified bonus_approve bonus_reject request_edd_document_upload
                p2p_order_confirm_verify p2p_limit_changed p2p_limit_upgrade_available mt5_change_color poa_verification_expired poa_verification_warning poi_poa_resubmission
                verify_email_closed_account_reset_password verify_email_closed_account_account_opening verify_email_closed_account_other request_payment_withdraw
                account_opening_existing self_tagging_affiliates authenticated_with_scans document_uploaded new_mt5_signup_stored
                identity_verification_rejected p2p_advertiser_approved p2p_order_updated_handled
                risk_disclaimer_resubmission unknown_login derivx_account_deactivated poa_verification_failed_reminder professional_status_requested dp_successful_login pa_first_time_approved shared_payment_method_email_notification
                pa_transfer_confirm pa_withdraw_confirm derivez_inactive_notification derivez_inactive_account_closed/
        ),
        'Correct number of actions that can be emitted'
    );

    is(ref($action_mappings->{$_}), 'CODE', 'event handler is a code reference') for keys %$action_mappings;
};

subtest 'process - mt5 retryable jobs' => sub {
    my $proc            = BOM::Event::Process->new(category => 'mt5_retryable');
    my $action_mappings = $proc->actions;

    cmp_deeply([keys %$action_mappings], bag(qw/link_myaff_token_to_mt5 mt5_deposit_retry/), 'Correct number of actions that can be emitted');

    is(ref($action_mappings->{$_}), 'CODE', 'event handler is a code reference') for keys %$action_mappings;
};

subtest 'request in process' => sub {
    my $proc = BOM::Event::Process->new(category => 'generic');

    my $mock_process = Test::MockModule->new('BOM::Event::Process');
    $mock_process->redefine(
        'actions' => sub {
            return {
                get_request => sub {
                    return BOM::Platform::Context::request();
                }
            };
        });

    my $request = $proc->process({
            type    => 'get_request',
            details => {}
        },
        QUEUE_NAME
    );
    is($request->brand_name, 'deriv', 'default brand name is deriv');
    is($request->language,   'EN',    'default language is EN');

    $request = $proc->process({
            type    => 'get_request',
            details => {},
            context => {
                brand_name => 'binary',
                language   => 'CN'
            }
        },
        QUEUE_NAME
    );
    is($request->brand_name, 'binary', 'now brand name is binary now');
    is($request->language,   'CN',     'now language is CN');

};

done_testing();
