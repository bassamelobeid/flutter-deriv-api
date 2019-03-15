package BOM::Test::Helper::Redis;
use strict;
use warnings;

use Exporter 'import';
use Test::More;

use constant MAX_REDIS_KEYS => 41;

our @EXPORT_OK = qw( is_within_threshold );

use namespace::clean -except => [qw(import)];

sub is_within_threshold ($$;$) {    ## no critic (Subroutines::ProhibitSubroutinePrototypes)
    my ($server, $res, $threshold) = @_;
    $threshold //= MAX_REDIS_KEYS;

    fail "No Redis server given!"
        unless $server;

    fail "Redis response is invalid!"
        unless $res and ref $res eq 'HASH';

    note "Checking for number of Redis keys on $server";

    # A Redis may have more than one database, so compare each
    # database's number of used keys against the threshold
    for my $db (grep { /^db[0-9]+/ } keys %$res) {
        # get number of keys from https://redis.io/commands/INFO keyspace
        # output format is like: 'keys=XXX,expires=XXX'
        my %stats = split /[,=]/, $res->{$db};
        cmp_ok $stats{keys}, '<=', $threshold, "Current number of Redis keys ($stats{keys}) for $server ($db) within threshold ($threshold)";
    }

    return undef;
}

1;
__END__

=encoding utf-8

=head1 NAME

BOM::Test::Helper::Redis - Helper for testing Redis keys

=head1 SYNOPSIS

    # in a test script elswhere that uses Redis
    use BOM::Test::Helper::Redis 'is_within_threshold';

    ...;
    my $redis_info = get_redis_info();
    is_within_threshold $db, $redis_info;

=head1 DESCRIPTION

L<BOM::Test::Helper::Redis> provides a helper for checking if the number
of Redis keys in a database exceeds a set threshold.

L<BOM::Test::Helper::Redis> does not export any functions by default.

=head1 FUNCTIONS

=head2 is_within_threshold

    is_within_threshold($db, $redis_info, [$threshold]);

Given the name of a Redis database and a hashref of its server info
(from a Redis `INFO` command,) this function reads the compares the
number of Redis keys stated in the server info against a given
threshold.  If no threshold is given, this function will use a default
set in this module's C<MAX_REDIS_KEYS>.

=head1 SEE ALSO

=over 4

=item L<Binary::WebSocketAPI::v3::Instance::Redis>

Used in binary-websocket-api.

=item L<BOM::Config::RedisReplicated>

Used in bom-rpc.

=back

=cut
