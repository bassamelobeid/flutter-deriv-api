use Object::Pad;

package BOM::User::ExecutionContext;

use Carp;
use Scalar::Util;

=head1 NAME

BOM::User::ExecutionContext - Class representing the execution context for a user in the system.

=head1 DESCRIPTION

This class represents the execution context for a user in the system. It contains instances of the BOM::User::UserRegistry and BOM::User::ClientRegistry classes.

=head1 SYNOPSIS

    use BOM::User::ExecutionContext;

    my $execution_context = BOM::User::ExecutionContext->new;

=head1 METHODS

=head2 new

Constructor method for the class. Creates a new instance of the BOM::User::ExecutionContext class.

=head2 user_registry

Returns the user registry instance.

=head2 client_registry

Returns the client registry instance.

=head1 ATTRIBUTES

=head2 $user_registry

Instance of BOM::User::UserRegistry class.

=head2 $client_registry

Instance of BOM::User::ClientRegistry class.

=cut

class BOM::User::ExecutionContext {
    field $user_registry;    # Instance of BOM::User::UserRegistry class.
    field $client_registry;    # Instance of BOM::User::ClientRegistry class.

    # Constructor method for the class.
    BUILD {
        $user_registry   = BOM::User::UserRegistry->new;
        $client_registry = BOM::User::ClientRegistry->new;
    }

    method client_registry () {
        return $client_registry;
    }

    method user_registry () {
        return $user_registry;
    }
}

=head1 NAME

BOM::User::ClientRegistry - A registry of clients for the execution context.

=head1 DESCRIPTION

This class represents a registry of clients for the execution context.

=head1 METHODS

=head2 get_client

This method retrieves a client from the registry based on the loginid and db_operation.
It throws an exception if either parameter is missing.

=head3 Parameters

=over 4

=item * $loginid - The loginid of the client to retrieve.

=item * $db_operation - The db_operation of the client to retrieve.

=back

=head3 Returns

The client object.

=head2 add_client

This method adds a client to the registry.
It throws an exception if the client object is invalid or if there is already a client with the same loginid and db_operation in the registry.

=head3 Parameters

=over 4

=item * $client - The client object to add.

=back

=head3 Returns

The added client object.

=cut

class BOM::User::ClientRegistry {
    field %store;

    method get_client ($loginid, $db_operation) {
        Carp::croak "loginid and db_operations are required" unless $loginid && $db_operation;

        return $store{$loginid}{$db_operation};
    }

    method add_client ($client) {
        Carp::croak "Client object is required" unless Scalar::Util::blessed($client) && $client->isa('BOM::User::Client');

        my $loginid      = $client->loginid || Carp::croak 'Invalid client object, no loginid found';
        my $db_operation = $client->get_db  || Carp::croak 'Invalid client object, no db operation found';

        Carp::croak "Duplicate object in execution context for $loginid $db_operation" if $store{$loginid}{$db_operation};

        $store{$loginid}{$db_operation} = $client;

        return $client;
    }
}

=head1 NAME

BOM::User::UserRegistry - A class for managing user objects

=head1 DESCRIPTION

This class provides methods for managing user objects, including adding, retrieving, and searching for users by ID or email.

=head1 METHODS

=head2 get_user($id)

Retrieves a user object by ID.

=head2 get_user_by_email($email)

Retrieves a user object by email.

=head2 add_user($user)

Adds a user object to the registry.

=cut

class BOM::User::UserRegistry {
    field %store_by_id;
    field %store_by_email;

    method get_user ($id) {
        Carp::croak 'User id is required' unless $id;

        return $store_by_id{$id};
    }

    method get_user_by_email ($email) {
        Carp::croak 'Email is required' unless $email;

        return $store_by_email{$email};
    }

    method add_user ($user) {
        Carp::croak "User object is required" unless Scalar::Util::blessed($user) && $user->isa('BOM::User');

        my $id    = $user->id    || Carp::croak 'Invalid user object, no id found';
        my $email = $user->email || Carp::croak 'Invalid user object, no id found';

        Carp::croak "Duplicate object in execution context for user $id" if $store_by_id{$id};

        $store_by_id{$id}       = $user;
        $store_by_email{$email} = $user;

        return $user;
    }
}

1;
