package BOM::Test::WebsocketAPI::Redis::Transaction;

use strict;
use warnings;
no indirect;

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::Transaction

=head1 DESCRIPTION

A class repsenting clients to the transaction redis server (B<redis_transaction>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=head2

=cut

sub _build_config {
    return YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_TRANSACTION} // '/etc/rmg/redis-transaction.yml');
}

1;
