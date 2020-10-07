package BOM::Test::Helper::Redis;
use strict;
use warnings;

use Exporter 'import';
use Test::More;
use Syntax::Keyword::Try;
use BOM::Test;

use constant MAX_REDIS_KEYS => 85;

our @EXPORT_OK = qw( is_within_threshold );

use namespace::clean -except => [qw(import)];

sub is_within_threshold ($$;$) {    ## no critic (Subroutines::ProhibitSubroutinePrototypes)
    my ($redis_name, $redis, $threshold) = @_;
    $threshold //= MAX_REDIS_KEYS;

    fail "No Redis redis_name given!"
        unless $redis_name;

    note "Checking for number of Redis keys on $redis_name";
    my $total_keys_count = $redis->get(BOM::Test::REDIS_KEY_COUNTER) || 0;
    cmp_ok $total_keys_count , '<=', $threshold, "Current number of Redis keys ($total_keys_count}) for $redis_name within threshold ($threshold)";
    # When we call this funciton, that means this variable has finished its mission. So we delete it to avoid keeping increasing.
    try {
        $redis->del(BOM::Test::REDIS_KEY_COUNTER);
    } catch ($e) {
        die $e unless $e =~ /EADONLY You can't write against a read only slave/;
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

    is_within_threshold($redis_name, $redis_object, [$threshold]);

Given the name of a Redis database and a redis object, this function reads the compares the
number of Redis keys stated in the server info against a given
threshold.  If no threshold is given, this function will use a default
set in this module's C<MAX_REDIS_KEYS>.

=head1 SEE ALSO

=over 4

=item L<Binary::WebSocketAPI::v3::Instance::Redis>

Used in binary-websocket-api.

=item L<BOM::Config::Redis>

Used in bom-rpc.

=back

=cut
