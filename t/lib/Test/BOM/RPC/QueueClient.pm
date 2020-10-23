package Test::BOM::RPC::QueueClient;

use strict;
use warnings;

use Test::More;
use Data::Dumper;

use BOM::Test::RPC::QueueClient;

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 tcall

Dispatch request by RPC Queue dispatcher

Returns hashref

=cut

sub tcall {
    my ($self, $method, $params) = @_;

    my $client = BOM::Test::RPC::QueueClient->new();
    my $r      = $client->_tcall($method, $params);

    ok($r->result,    "RPC response ok for method: $method");
    ok(!$r->is_error, "RPC response didn't contain errors for method: $method");

    diag(Dumper($r)) if ($r->is_error);

    return $r->result;
}

1;
