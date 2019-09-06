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

initialize_events_redis();

use constant QUEUE_NAME => 'GENERIC_EVENTS_QUEUE';

my $count  = 0;
my @events = ({
        'register_details' => {
            loginid => 'CR121',
            email   => 'abc1@binary.com'
        }
    },
    {
        'register_details' => {
            loginid => 'CR122',
            email   => 'abc2@binary.com'
        }
    },
    {
        'register_details' => {
            loginid => 'CR123',
            email   => 'abc3@binary.com'
        }
    },
    {
        'register_details' => {
            loginid => 'CR124',
            email   => 'abc4@binary.com'
        }
    },
    {
        'register_details' => {
            loginid => 'CR125',
            email   => 'abc5@binary.com'
        }
    },
    {
        'register_details' => {
            loginid => 'CR126',
            email   => 'abc6@binary.com'
        }
    },
    {
        'email_consent' => {
            loginid       => 'CR121',
            email_consent => 1
        }
    },
    {
        'email_consent' => {
            loginid       => 'CR122',
            email_consent => 0
        }
    },
    {
        'email_consent' => {
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

    is_deeply(
        [sort keys %{BOM::Event::Process::get_action_mappings()}],
        [
            sort qw/email_consent register_details email_statement sync_user_to_MT5
                store_mt5_transaction new_mt5_signup anonymize_client send_mt5_disable_csv
                document_upload ready_for_authentication account_closure client_verification
                verify_address social_responsibility_check sync_onfido_details
                set_pending_transaction authenticated_with_scans qualifying_payment_check payment_deposit/
        ],
        'Correct number of actions that can be emitted'
    );

    BOM::Event::Process::process({}, QUEUE_NAME);
    $log->contains_ok(qr/no function mapping found for event <unknown> from queue GENERIC_EVENTS_QUEUE/, 'Empty message not processed');

    BOM::Event::Process::process({type => 'dummy_action'}, QUEUE_NAME);
    $log->contains_ok(qr/no function mapping found for event dummy_action from queue GENERIC_EVENTS_QUEUE/,
        'Process cannot be processed as function action is not available');

    BOM::Event::Process::process({type => 'email_consent'}, QUEUE_NAME);
    $log->contains_ok(qr/event email_consent from queue GENERIC_EVENTS_QUEUE contains no details/,
        'Process cannot be processed as no details is given');

    my $mock_process = Test::MockModule->new('BOM::Event::Process');
    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                register_details => sub { return 'Details registered'; },
                email_consent    => sub { return 'Unsubscribe flag updated'; },
                email_statement  => sub { return 'Statement has been sent'; }
            };
        });

    is BOM::Event::Process::process({
            type    => 'register_details',
            details => {}
        },
        QUEUE_NAME
        ),
        'Details registered', 'Invoked associated sub for register_details event';
    is BOM::Event::Process::process({
            type    => 'email_consent',
            details => {}
        },
        QUEUE_NAME
        ),
        'Unsubscribe flag updated', 'Invoked associated sub for register_details event';

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
                register_details => sub { die 'Error - connection error'; },
                email_consent    => sub { die 'Error - connection error'; },
                email_statement  => sub { die 'Error - connection error'; },
            };
        });

    is BOM::Event::Process::process({
            type    => 'register_details',
            details => {}
        },
        QUEUE_NAME
        ),
        0, 'If internal method die then process should just return false not die';

    is BOM::Event::Process::process({
            type    => 'email_consent',
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

done_testing();
