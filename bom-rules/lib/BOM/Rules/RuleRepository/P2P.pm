package BOM::Rules::RuleRepository::P2P;

=head1 NAME

BOM::Rules::RuleRepository::P2P

=head1 DESCRIPTION

This modules declares rules and regulations related to P2P.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use Format::Util::Numbers qw(financialrounding formatnumber);

rule 'p2p.no_open_orders' => {
    description => "Fails if the client has any open P2P orders.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        my $orders = $client->_p2p_orders(
            loginid => $args->{loginid},
            active  => 1,
        );

        $self->fail('OpenP2POrders') if @$orders;

        return 1;
    },
};

1;
