use strict;
use warnings;

use Log::Any::Test;
use Log::Any qw($log);

use Test::Fatal;
use Test::MockModule;
use Test::More;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Platform::Event::Emitter;
use BOM::Event::Process;
use BOM::Platform::Context;

initialize_events_redis();

use constant QUEUE_NAME => 'GENERIC_EVENTS_QUEUE';

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

subtest 'process' => sub {
    my $action_mappings = BOM::Event::Process::get_action_mappings();
    is_deeply(
        [sort keys %$action_mappings],
        [
            sort qw/email_statement sync_user_to_MT5 send_email
                store_mt5_transaction new_mt5_signup mt5_password_changed anonymize_client bulk_anonymization
                document_upload ready_for_authentication account_closure client_verification
                verify_address social_responsibility_check sync_onfido_details
                crypto_subscription authenticated_with_scans qualifying_payment_check payment_deposit payment_withdrawal payment_withdrawal_reversal
                login signup transfer_between_accounts profile_change
                p2p_advertiser_created p2p_advertiser_updated
                p2p_advert_created p2p_advert_updated
                p2p_order_created p2p_order_updated p2p_order_expired p2p_timeout_refund p2p_dispute_expired p2p_chat_received
                affiliate_sync_initiated withdrawal_limit_reached
                api_token_created api_token_deleted
                app_registered app_updated app_deleted self_exclude set_financial_assessment crypto_withdrawal aml_client_status_update
                client_promo_codes_upload new_crypto_address onfido_doc_ready_for_upload shared_payment_method_found multiplier_hit_type
                dispute_notification account_reactivated mt5_inactive_notification/
        ],
        'Correct number of actions that can be emitted'
    );

    is(ref($action_mappings->{$_}), 'CODE', 'event handler is a code reference') for keys %$action_mappings;

    BOM::Event::Process::process({}, QUEUE_NAME);
    $log->contains_ok(qr/no function mapping found for event <unknown> from queue GENERIC_EVENTS_QUEUE/, 'Empty message not processed');

    BOM::Event::Process::process({type => 'dummy_action'}, QUEUE_NAME);
    $log->contains_ok(qr/no function mapping found for event dummy_action from queue GENERIC_EVENTS_QUEUE/,
        'Process cannot be processed as function action is not available');

    my $mock_process = Test::MockModule->new('BOM::Event::Process');
    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                signup          => sub { return 'Details registered'; },
                profile_change  => sub { return 'Unsubscribe flag updated'; },
                email_statement => sub { return 'Statement has been sent'; }
            };
        });

    is BOM::Event::Process::process({
            type    => 'signup',
            details => {}
        },
        QUEUE_NAME
        ),
        'Details registered', 'Invoked associated sub for signup event';
    is BOM::Event::Process::process({
            type    => 'profile_change',
            details => {}
        },
        QUEUE_NAME
        ),
        'Unsubscribe flag updated', 'Invoked associated sub for profile_change event';

    is BOM::Event::Process::process({
            type    => 'email_statement',
            details => {}
        },
        QUEUE_NAME
        ),
        'Statement has been sent', 'Invoked associated sub for email_statement event';

    $mock_process->unmock('get_action_mappings');

    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                signup          => sub { die 'Error - connection error'; },
                profile_change  => sub { die 'Error - connection error'; },
                email_statement => sub { die 'Error - connection error'; },
            };
        });

    is BOM::Event::Process::process({
            type    => 'signup',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    is BOM::Event::Process::process({
            type    => 'profile_change',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    is BOM::Event::Process::process({
            type    => 'email_statement',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    $mock_process->unmock('get_action_mappings');
};

subtest 'request in process' => sub {
    my $mock_process = Test::MockModule->new('BOM::Event::Process');
    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                get_request => sub {
                    return BOM::Platform::Context::request();
                }
            };
        });
    my $request = BOM::Event::Process::process({
            type    => 'get_request',
            details => {}
        },
        QUEUE_NAME
    );
    is($request->brand_name, 'deriv', 'default brand name is deriv');
    is($request->language,   'EN',    'default language is EN');

    $request = BOM::Event::Process::process({
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
