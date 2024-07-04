package BOM::Event::Actions::DynamicWorks;

use strict;
use warnings;

use Log::Any qw($log);
use Future::AsyncAwait;

use BOM::MyAffiliates::DynamicWorks::Integration;
use BOM::Config::Runtime;

=head2 link_user_to_dw_affiliate

This method links a user to a Dynamic Works affiliate.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - binary_user_id: The binary user ID of the user (required).

=item - sidc: The SIDC of the affiliate.

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

A hash reference containing either an error message or the result of the operation.

=back

=cut

async sub link_user_to_dw_affiliate {

    my $args = shift;

    BOM::Config::Runtime->instance->app_config->check_for_update();
    my $dynamic_works_enabled = BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

    return unless $dynamic_works_enabled;

    my $dynamicworks_integration = BOM::MyAffiliates::DynamicWorks::Integration->new;
    return $dynamicworks_integration->link_user_to_affiliate($args);
}

1;
