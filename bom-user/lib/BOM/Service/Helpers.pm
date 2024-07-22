package BOM::Service::Helpers;

use strict;
use warnings;
no indirect;

use Text::Trim qw(trim);
use Date::Utility;
use List::Util   qw(first any all minstr uniq);
use Scalar::Util qw(blessed looks_like_number);
use Carp         qw(croak carp);
use Cache::LRU;
use Time::HiRes qw(gettimeofday tv_interval);
use Digest::SHA qw(sha1_hex);
use UUID::Tiny;
use BOM::User;
use BOM::User::Client;

use constant {
    CACHE_OBJECT_EXPIRY => 2,
    CACHE_SIZE          => 20,
};

our $user_object_cache   = Cache::LRU->new(size => CACHE_SIZE);
our $client_object_cache = Cache::LRU->new(size => CACHE_SIZE);

=pod

=head2 get_user_object

    get_user_object($user_identifier, $correlation_id)

This method retrieves a user object from the cache or creates a new one if it doesn't exist. It takes two arguments:

=over 4

=item * C<$user_identifier>: A unique identifier for the user. This can be a numeric ID, a UUID, or an email address.

=item * C<$correlation_id>: An identifier used for tracking the request across multiple services or processes.

=back

The method generates two cache keys and retrieves the user object from the cache. If the user object is not found or the cache has expired, a new user object is created and stored in the cache.

The method returns the user object.

=cut

sub get_user_object {
    my ($user_identifier, $correlation_id) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to get_user_object not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $cache_key_main      = "$correlation_id:$user_identifier";
    my $binary_user_id      = _user_identifier_to_binary_user_id($user_identifier);
    my $cache_key_secondary = defined $binary_user_id ? "$correlation_id:$binary_user_id" : "$correlation_id:$user_identifier";
    my $cache_entry         = $user_object_cache->get($cache_key_main) // $user_object_cache->get($cache_key_secondary);

    # Invalidate the user if cache expired
    $cache_entry = undef if (defined $cache_entry && tv_interval($cache_entry->{time}) > CACHE_OBJECT_EXPIRY);
    # Invalidate the user if the number of clients has changed
    $cache_entry = undef if (defined $cache_entry && $cache_entry->{loginids} != _get_loginid_count($binary_user_id));

    # If no user object is found in the cache, create a new one
    unless (defined $cache_entry) {
        my $user_object;
        if (defined $binary_user_id) {
            $user_object = BOM::User->new(
                id           => $binary_user_id,
                db_operation => 'write'
            );
        } else {
            $user_object = BOM::User->new(
                email        => $user_identifier,
                db_operation => 'write'
            );
        }
        die "UserNotFound|::|Could not find a user object for '$user_identifier'" unless defined $user_object;

        $cache_entry = {
            time     => [gettimeofday],
            loginids => _get_loginid_count($binary_user_id),
            object   => $user_object
        };
        $user_object_cache->set($cache_key_main,      $cache_entry);
        $user_object_cache->set($cache_key_secondary, $cache_entry);
    }
    return $cache_entry->{object};
}

=pod

=head2 flush_user_cache

    flush_user_cache($user_identifier, $correlation_id)

This method is used to remove a user's data from the cache. It takes two arguments:

=over 4

=item * C<$user_identifier>: A unique identifier for the user. This can be a numeric ID, a UUID, or an email address.

=item * C<$correlation_id>: An identifier used for tracking the request across multiple services or processes.

=back

The method first checks if the caller is within the BOM::Service namespace. If not, it dies with an access denied error.

It then generates two cache keys: one using the correlation ID and the user identifier, and another using the correlation ID and the binary user ID (if it exists).

Finally, it removes the user's data from the cache using these keys.

This method does not return any value.

=cut

sub flush_user_cache {
    my ($user_identifier, $correlation_id) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to flush_user_cache not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $cache_key_main      = "$correlation_id:$user_identifier";
    my $binary_user_id      = _user_identifier_to_binary_user_id($user_identifier);
    my $cache_key_secondary = defined $binary_user_id ? "$correlation_id:$binary_user_id" : "$correlation_id:$user_identifier";

    $user_object_cache->remove($cache_key_main);
    $user_object_cache->remove($cache_key_secondary);
}

=pod

=head2 get_client_object

    get_client_object($user_identifier, $correlation_id)

This method retrieves a client object from the cache or creates a new one if it doesn't exist. It takes two arguments:

=over 4

=item * C<$user_identifier>: A unique identifier for the user. This can be a numeric ID, a UUID, or an email address.

=item * C<$correlation_id>: An identifier used for tracking the request across multiple services or processes.

=back

The method generates two cache keys and retrieves the client object from the cache. If the client object is not found or the cache has expired, a new client object is created and stored in the cache.

The method returns the client object.

=cut

sub get_client_object {
    my ($user_identifier, $correlation_id) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to get_client_object not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $cache_key_main      = "$correlation_id:$user_identifier";
    my $binary_user_id      = _user_identifier_to_binary_user_id($user_identifier);
    my $cache_key_secondary = defined $binary_user_id ? "$correlation_id:$binary_user_id" : "$correlation_id:$user_identifier";

    my $cache_entry = $client_object_cache->get($cache_key_main) // $client_object_cache->get($cache_key_secondary);

    # Invalidate the user if cache expired
    $cache_entry = undef if (defined $cache_entry && tv_interval($cache_entry->{time}) > CACHE_OBJECT_EXPIRY);
    # Invalidate the user if the number of clients has changed
    $cache_entry = undef if (defined $cache_entry && $cache_entry->{loginids} != _get_loginid_count($binary_user_id));

    unless (defined $cache_entry) {
        my $user_object = get_user_object($user_identifier, $correlation_id);
        die "UserNotFound|::|Could not find a user object for '$user_identifier'" unless defined $user_object;
        my $client_object = $user_object->get_default_client(
            db_operation     => 'write',
            include_disabled => 1
        );
        die "ClientNotFound|::|Could not find a default_client object for '$user_identifier'" unless defined $client_object;
        $cache_entry = {
            time     => [gettimeofday],
            loginids => _get_loginid_count($binary_user_id),
            object   => $client_object
        };

        $client_object_cache->set($cache_key_main,      $cache_entry);
        $client_object_cache->set($cache_key_secondary, $cache_entry);
    }
    return $cache_entry->{object};
}

=pod

=head2 flush_client_cache

    flush_client_cache($user_identifier, $correlation_id)

This method removes a client's data from the cache. It takes two arguments:

=over 4

=item * C<$user_identifier>: A unique identifier for the user. This can be a numeric ID, a UUID, or an email address.

=item * C<$correlation_id>: An identifier used for tracking the request across multiple services or processes.

=back

The method generates two cache keys and removes the client object from the cache using these keys.

=cut

sub flush_client_cache {
    my ($user_identifier, $correlation_id) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to flush_client_cache not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $cache_key_main      = "$correlation_id:$user_identifier";
    my $binary_user_id      = _user_identifier_to_binary_user_id($user_identifier);
    my $cache_key_secondary = defined $binary_user_id ? "$correlation_id:$binary_user_id" : "$correlation_id:$user_identifier";

    $client_object_cache->remove($cache_key_main);
    $client_object_cache->remove($cache_key_secondary);
}

=pod

=head2 binary_user_id_to_uuid

    binary_user_id_to_uuid($binary_user_id)

This method converts a binary user ID into a UUID. It takes one argument:

=over 4

=item * C<$binary_user_id>: A binary user ID that must be greater than 0 and not more than 12 digits.

=back

The method generates a UUID by creating a hash of the binary user ID and formatting it into a UUID string.

The method returns the generated UUID.

=cut

sub binary_user_id_to_uuid {
    my ($binary_user_id) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to binary_user_id_to_uuid not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    die "Could not convert id to UUID, input must be greater than 0"             if $binary_user_id <= 0;
    die "Could not convert id to UUID, input must not be greater than 12 digits" if length($binary_user_id) > 12;

    # Not salting here, its not for cryptographic purposes, just for a checksum
    my $id_with_hash = sprintf("%012d", $binary_user_id) . sha1_hex($binary_user_id);

    # Ensure the version (4) and the variant (10xx) bits are set correctly, we are wasting 2 bits
    # here on the variant but it's not a big deal.
    my $uuid = sprintf(
        '%s-%s-4%s-8%s-%s',
        substr($id_with_hash, 0,  8),    # 8 characters
        substr($id_with_hash, 8,  4),    # 4 characters
        substr($id_with_hash, 12, 3),    # 3 characters (first character of this part is part of the version)
        substr($id_with_hash, 15, 3),    # 3 characters
        substr($id_with_hash, 18, 12));    # 12 characters

    return $uuid;
}

=pod

=head2 uuid_to_binary_user_id

    uuid_to_binary_user_id($uuid)

This method converts a UUID into a binary user ID. It takes one argument:

=over 4

=item * C<$uuid>: A UUID that must be in the format of 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.

=back

The method removes dashes from the UUID, extracts the zero-padded binary user ID, and converts it back to an integer. It then generates an expected UUID based on the binary user ID and compares it with the original UUID.

The method returns the binary user ID if the conversion is successful.

=cut

sub uuid_to_binary_user_id {
    my ($uuid) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to uuid_to_binary_user_id not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    unless ($uuid =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/) {
        die "Invalid UUID: '$uuid'";
    }

    # Remove dashes and extract the zero-padded binary_user_id and the hash part
    my $uuid_without_dashes        = $uuid =~ s/-//gr;
    my $zero_padded_binary_user_id = substr($uuid_without_dashes, 0, 12);

    # Sanity check, should always be numeric unless real UUID and perl never supporting that atm
    unless ($zero_padded_binary_user_id =~ /^\d+$/) {
        die "Could not convert UUID to binary_user_id, non numeric lead-in: '$uuid'";
    }
    # Convert zero-padded binary_user_id back to integer
    my $binary_user_id = int($zero_padded_binary_user_id);
    die "Could not convert UUID to binary_user_id, resultant uuid is <= 0" if $binary_user_id <= 0;

    # Generate the expected hash based on the binary_user_id
    my $expected_uuid = binary_user_id_to_uuid($binary_user_id);

    # Compare the extracted hash portion with the expected hash
    if ($uuid ne $expected_uuid) {
        die "Could not convert UUID to binary_user_id, hash fail: '$uuid'";
    }

    return $binary_user_id;
}

=pod

=head2 _user_identifier_to_binary_user_id

    _user_identifier_to_binary_user_id($user_identifier)

This private method converts a user identifier into a binary user ID. It takes one argument:

=over 4

=item * C<$user_identifier>: A unique identifier for the user. This can be a numeric ID, a UUID, or an email address.

=back

The method checks the type of the user identifier and converts it to a binary user ID accordingly. If the user identifier is a number, it is returned as is. If it is a UUID, it is converted to a binary user ID using the `uuid_to_binary_user_id` function. If it is an email, `undef` is returned.

The method returns the binary user ID.

=cut

sub _user_identifier_to_binary_user_id {
    my ($user_identifier) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to _user_identifier_to_binary_user_id not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $binary_user_id;
    # Users can be referenced via number, uuid or email
    if (looks_like_number($user_identifier)) {
        if ($user_identifier <= 0 || $user_identifier > 999999999999) {
            die "Invalid numeric user identifier: '$user_identifier'";
        }
        $binary_user_id = $user_identifier;
    } elsif ($user_identifier =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/) {
        $binary_user_id = uuid_to_binary_user_id($user_identifier);
    } elsif ($user_identifier =~ /^.+@.+\..+$/) {
        # All emails have an @ and min one .
        $binary_user_id = undef;
    } else {
        die "Unrecognised type of user identifier: '$user_identifier'";
    }
    return $binary_user_id;
}

=head2 _get_loginid_count

Given a binary user ID, this method retrieves the count of login IDs associated with the user from the database.

=head3 Arguments

=over 4

=item *

C<$binary_user_id> - A binary representation of the user ID.

=back

=head3 Returns

The number of login IDs associated with the user.

=cut

sub _get_loginid_count {
    my $binary_user_id = shift;

    my $loginids = BOM::User->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('select loginid from users.get_loginids(?)', {Slice => {}}, $binary_user_id);
        });

    return scalar @$loginids;
}
1;
