use strict;
use warnings;

use Test::Fatal;
use Test::MockModule;
use Test::More;

use BOM::Platform::Event::Register;
use BOM::Platform::Event::Process;
use BOM::Platform::Event::Listener;

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
        'dummy_event' => {
            loginid       => 'CR123',
            email_consent => 1
        }
    },
);

subtest 'register' => sub {
    like(
        exception {
            BOM::Platform::Event::Register::register();
        },
        qr/Missing required parameter: type./,
        'missing action parameter',
    );

    like(
        exception {
            BOM::Platform::Event::Register::register('dummy');
        },
        qr/Missing required parameter: data./,
        'missing data parameter',
    );

    is BOM::Platform::Event::Register::get(), undef, 'No event is present so it should return undef';

    foreach my $event (@events) {
        my $action = (keys %$event)[0];
        $count = BOM::Platform::Event::Register::register($action, $event->{$action});
    }

    is $count, 10, 'Correct number of event registered';
};

subtest 'listen' => sub {
    foreach (1 .. $count) {
        BOM::Platform::Event::Listener::run_once();
    }

    is BOM::Platform::Event::Register::register('sample', {sample => 1}), 1, 'Listener pop previous entries so only new one is there';

    note "Clearing out last entry for keeping clean state";
    BOM::Platform::Event::Listener::run_once();
};

subtest 'process' => sub {
    is_deeply(
        [sort keys %{BOM::Platform::Event::Process::get_action_mappings()}],
        [qw/email_consent register_details/],
        'Correct number of actions that can be registered'
    );

    is BOM::Platform::Event::Process::process({dummy_action => {}}), undef, 'Cannot process action that is not in the allowed list';

    my $mock_process = Test::MockModule->new('BOM::Platform::Event::Process');
    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                register_details => sub { return 'Details registered'; },
                email_consent    => sub { return 'Unsubscribe flag updated'; },
            };
        });

    is BOM::Platform::Event::Process::process({
            type    => 'register_details',
            details => {}}
        ),
        'Details registered', 'Invoked associated sub for register_details event';
    is BOM::Platform::Event::Process::process({
            type    => 'email_consent',
            details => {}}
        ),
        'Unsubscribe flag updated', 'Invoked associated sub for register_details event';

    $mock_process->unmock('get_action_mappings');

    $mock_process->mock(
        'get_action_mappings' => sub {
            return {
                register_details => sub { die 'Error - connection error'; },
                email_consent    => sub { die 'Error - connection error'; },
            };
        });

    is BOM::Platform::Event::Process::process({
            type    => 'register_details',
            details => {}}
        ),
        0, 'If internal method die then process should just return false not die';

    is BOM::Platform::Event::Process::process({
            type    => 'email_consent',
            details => {}}
        ),
        0, 'If internal method die then process should just return false not die';

    $mock_process->unmock('get_action_mappings');
};

done_testing();
