package BOM::Event::Actions::OTC;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::OTC - deal with OTC events

=head1 DESCRIPTION

The peer-to-peer cashier feature (or "OTC" for over-the-counter) provides a way for
buyers and sellers to transfer funds using whichever methods they are able to negotiate
between themselves directly.

=cut

no indirect;

use Log::Any qw($log);

use BOM::Platform::Context qw(request);
use BOM::Platform::Event::Emitter;

=head2 agent_created

When there's a new request to sign up as an agent,
we'd presumably want some preliminary checks and
then mark their status as C<approved> or C<active>.

Currently there's a placeholder email.

=cut

sub agent_created {
    BOM::Platform::Event::Emitter::emit(
        send_email_generic => {
            to      => 'compliance@binary.com',
            subject => 'New OTC agent registered',
        });
    return;
}

=head2 agent_updated

An update to an agent - different name, for example - may
be relevant to anyone with an active order.

=cut

sub agent_updated {
    return;
}

=head2 offer_created

An agent has created a new offer. This is always triggered
even if the agent has marked themselves as inactive, so
it's important to check agent status before sending
any client notifications here.

=cut

sub offer_created {
    return;
}

=head2 offer_updated

An existing offer has been updated. Either that's because the
an order has closed (confirmed/cancelled), or the details have
changed.

=cut

sub offer_updated {
    return;
}

=head2 order_created

An order has been created against an offer.

=cut

sub order_created {
    return;
}

=head2 order_updated

An existing order has been updated. Typically these would be status updates.

=cut

sub order_updated {
    return;
}

=head2 order_expired

An order reached our predefined timeout without being confirmed by both sides or
cancelled by the client.

We'd want to do something here - perhaps just mark the order as expired.

=cut

sub order_expired {
    return;
}

1;

