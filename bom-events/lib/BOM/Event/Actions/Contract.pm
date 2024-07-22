package BOM::Event::Actions::Contract;

use strict;
use warnings;

use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::User::Client;
use BOM::Platform::Context qw(request);
use List::Util             qw(any);

=head1 NAME

BOM::Event::Actions::Contract

=head1 DESCRIPTION

Provides handlers for contract-related events.

=cut

no indirect;

=head2 multiplier_hit_type

It is triggered for each B<multiplier_hit_type> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub multiplier_hit_type {
    return BOM::Event::Services::Track::multiplier_hit_type(@_);
}

=head2 multiplier_near_expire_notification

It is triggered for each B<multiplier_near_expire_notification> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Hash-ref of event properties.

=back

=cut

sub multiplier_near_expire_notification {
    return BOM::Event::Services::Track::multiplier_near_expire_notification(@_);
}

=head2 multiplier_near_dc_notification

It is triggered for each B<multiplier_near_dc_notification> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Hash-ref of event properties.

=back

=cut

sub multiplier_near_dc_notification {
    return BOM::Event::Services::Track::multiplier_near_dc_notification(@_);
}

1;
