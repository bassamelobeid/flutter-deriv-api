package BOM::Platform::Redis;

=head1 NAME

BOM::Platform::Redis

=head1 DESCRIPTION

A collection of helper methods related to Rdis.

=cut

use strict;
use warnings;

use BOM::Config::Redis;

=head2 acquire_lock

Builds a lock in Redis.

Example usage:

    $aqcuire_lock(...);

    Takes the following arguments as named parameters

=over 2

=item * C<lockname> - a name against which lock is applied.

=item * C<acquire_timeout> - number of seconds after that lock will be expired and released.

=back 

Returns 1 if lock was acquired, 0 otherwise.

=cut

sub acquire_lock {
    my ($lockname, $acquire_timeout) = @_;

    my $caller_package = (caller 0)[0] // "";

    my $key = $caller_package . '_LOCK_' . $lockname;

    return 0 if not BOM::Config::Redis::redis_replicated_write()->set($key, 1, 'NX', 'EX', $acquire_timeout);

    return 1;
}

=head2 release_lock

Releases the lock in Redis.

Example usage:

    $release_lock(...);

    Takes the following arguments as named parameters

=over 1

=item * C<lockname> - the lock name against which lock was applied.

=back 

Returns 1 if lock was releases, 0 otherwise.

=cut

sub release_lock {
    my ($lockname) = @_;

    my $caller_package = (caller 0)[0] // "";

    my $key = $caller_package . '_LOCK_' . $lockname;

    return BOM::Config::Redis::redis_replicated_write()->del($key);
}

1;
