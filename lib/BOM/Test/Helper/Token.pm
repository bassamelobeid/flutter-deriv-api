package BOM::Test::Helper::Token;

use strict;
use warnings;

use Exporter qw(import);
use BOM::Test;
use BOM::Config::RedisReplicated;
use BOM::Platform::Token::API;

our @EXPORT_OK = qw(cleanup_redis_tokens generate_token);

=head2 cleanup_redis_tokens

Basically cleans up keys 'TOKEN*' in replicated redis

=cut

sub cleanup_redis_tokens {
    my $writer = BOM::Config::RedisReplicated::redis_auth_write();
    $writer->del($_) foreach @{$writer->keys('TOKEN*')};
    return;
}

=head2 generate_token

Generates token with the provided length

=cut

sub generate_token {
    my $length = shift;

    return BOM::Platform::Token::API->new->generate_token($length);
}

1;
