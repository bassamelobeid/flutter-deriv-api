use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper qw(record_failed_withdrawal);
use BOM::User::Client;
use Test::MockModule;

subtest 'Shared Payment Methods' => sub {
    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my @emit_args;
    $mock_emitter->mock(
        'emit',
        sub {
            @emit_args = @_;
            return $mock_emitter->original('emit')->(@emit_args);
        });

    my $client_email = 'client@binary.com';
    my $client       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $client_email,
        place_of_birth => 'br',
    });
    my $client_user = BOM::User->create(
        email    => $client_email,
        password => 'asdfqwerty9009'
    );
    $client_user->add_client($client);

    my $shared_email = 'shared@binary.com';
    my $shared       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $shared_email,
        place_of_birth => 'br',
    });
    my $shared_user = BOM::User->create(
        email    => $shared_email,
        password => 'asdfqwerty9009'
    );
    $shared_user->add_client($shared);

    my $r = record_failed_withdrawal(
        client_loginid => $client->loginid,
        error_desc     => sprintf('Shared AccountIdentifier PIN: %s', $shared->loginid),
        error_code     => 'NDB2006',
    );

    is($r->code, 200, 'correct status code');

    is $emit_args[0], 'shared_payment_method_found', 'Correct event emitted';
    cmp_deeply $emit_args[1],
        {
        'shared_loginid' => $shared->loginid,
        'client_loginid' => $client->loginid,
        },
        'Correct parameters sent to event';

    subtest 'Other error code should not trigger the event' => sub {
        @emit_args = ();
        $r         = record_failed_withdrawal(
            client_loginid => $client->loginid,
            error_desc     => sprintf('Shared AccountIdentifier PIN: %s', $shared->loginid),
            error_code     => 'SOME_OTHER_CODE',
        );
        is($r->code,          200, 'correct status code');
        is(scalar @emit_args, 0,   'Event not emitted');
    };
};

done_testing();
