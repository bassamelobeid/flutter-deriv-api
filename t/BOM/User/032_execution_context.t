use strict;
use warnings;
use Test::More;
use BOM::User::ExecutionContext;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Scalar::Util 'refaddr';

# Test the constructor
subtest 'constructor' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    isa_ok($execution_context, 'BOM::User::ExecutionContext', 'Execution context object created');
};

# Test the user_registry method
subtest 'user_registry' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $user_registry     = $execution_context->user_registry;
    isa_ok($user_registry, 'BOM::User::UserRegistry', 'User registry object returned');
};

# Test the client_registry method
subtest 'client_registry' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $client_registry   = $execution_context->client_registry;
    isa_ok($client_registry, 'BOM::User::ClientRegistry', 'Client registry object returned');
};

# Test the add_client and get_client methods of the ClientRegistry class
subtest 'client_registry add_client and get_client' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $client_registry   = $execution_context->client_registry;

    # Create a client object

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    # Test adding a client to the registry
    my $added_client = $client_registry->add_client($client);
    ok($added_client, 'Client added to registry');
    is($added_client->loginid, $client->loginid, 'Client added to registry');

    # Test retrieving a client from the registry
    my $retrieved_client = $client_registry->get_client($client->loginid, 'write');
    ok($retrieved_client, 'Client retrieved from registry');
    is($retrieved_client->loginid, $client->loginid, 'Client retrieved from registry');
};

# Test the add_user and get_user methods of the UserRegistry class
subtest 'user_registry add_user and get_user' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $user_registry     = $execution_context->user_registry;

    # Create a user object

    my $user = BOM::User->create(
        email    => 'testuser1@example.com',
        password => '123',
    );

    # Test adding a user to the registry
    my $added_user = $user_registry->add_user($user);
    ok($added_user, 'User added to registry');
    is($added_user->id, $user->id, 'User added to registry');

    # Test retrieving a user from the registry
    my $retrieved_user = $user_registry->get_user($user->id);
    ok($retrieved_user, 'user retrieved from registry');
    is($retrieved_user->id, $user->id, 'User retrieved from registry');
};

# Test the get_user_by_email method of the UserRegistry class
subtest 'user_registry get_user_by_email' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $user_registry     = $execution_context->user_registry;

    # Create a user object

    my $user = BOM::User->create(
        email    => 'testuser2@example.com',
        password => '123',
    );

    # Test adding a user to the registry
    my $added_user = $user_registry->add_user($user);
    ok($added_user, 'User added to registry');

    # Test retrieving a user from the registry
    my $retrieved_user = $user_registry->get_user_by_email($user->email);
    ok($retrieved_user, 'user retrieved from registry');
    is($retrieved_user->id, $user->id, 'User retrieved from registry');
};

subtest 'Creating user object with context' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $user_registry     = $execution_context->user_registry;

    # Create a user object and add to context
    my $user = BOM::User->create(
        email    => 'testuser3@example.com',
        password => '123',
        context  => $execution_context,
    );
    ok($user->{context}, 'User has context');

    # Get user from context by id and check it's the same object
    my $same_user = BOM::User->new(
        id      => $user->id,
        context => $execution_context
    );

    ok($same_user->{context}, 'User has context');

    ok($same_user, 'User object created with context');
    is($same_user->id,      $user->id,      'User object created with context');
    is(refaddr($same_user), refaddr($user), 'User objects are the same');

    # Get user from context by email and check it's the same object
    $same_user = BOM::User->new(
        email   => $user->email,
        context => $execution_context
    );
    ok($same_user, 'User object created with context');
    is($same_user->id,      $user->id,      'User object created with context');
    is(refaddr($same_user), refaddr($user), 'User objects are the same');

    # Test retrieving a user from the registry by login id
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $user->add_client($client);

    $same_user = BOM::User->new(
        loginid => $client->loginid,
        context => $execution_context
    );
    ok($same_user, 'User object created with context');
    is($same_user->id,      $user->id,      'User object created with context');
    is(refaddr($same_user), refaddr($user), 'User objects are the same');
};

subtest 'Creating Client object with context' => sub {
    my $execution_context = BOM::User::ExecutionContext->new;
    my $client_registry   = $execution_context->client_registry;

    # Create a user object and add to context
    my $user = BOM::User->create(
        email    => 'testuser4@example.com',
        password => '123',
        context  => $execution_context,
    );

    my $client = $user->create_client(
        client_password          => 'hello',
        first_name               => '',
        last_name                => '',
        myaffiliates_token       => '',
        email                    => 'testuser4@example.com',
        residence                => 'za',
        address_line_1           => '1 sesame st',
        address_line_2           => '',
        address_city             => 'cyberjaya',
        address_state            => '',
        address_postcode         => '',
        phone                    => '',
        secret_question          => '',
        secret_answer            => '',
        non_pep_declaration_time => time,
        broker_code              => 'VRTC',
    );
    ok($client->{context}, 'Client has context');

    my $same_client = BOM::User::Client->get_client_instance($client->loginid, $client->get_db, $execution_context);

    ok($same_client->{context}, 'Client has context');

    ok($same_client, 'Client object created with context');
    is($same_client->loginid, $client->loginid, 'Client object created with context');
    is(refaddr($same_client), refaddr($client), 'Client object is same');
    is($same_client->get_db,  $client->get_db,  'Client objects has same db connections');

    my $replica_client = BOM::User::Client->get_client_instance($client->loginid, 'replica', $execution_context);
    ok($replica_client, 'Replica client object created with context');
    is($replica_client->loginid, $client->loginid, 'Client object created with context');
    isnt(refaddr($replica_client), refaddr($client), 'Client object isnt same');
    isnt($replica_client->get_db,  $client->get_db,  'Client objects has differnt db connections');
};

done_testing;
