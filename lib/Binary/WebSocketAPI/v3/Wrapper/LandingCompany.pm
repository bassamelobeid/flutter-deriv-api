package Binary::WebSocketAPI::v3::Wrapper::LandingCompany;

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_inc);

=head2 map_landing_company

Maps the landing company in requests from C<costarica> to C<svg>.

This is because we switched from C<costarica> to C<svg> (April, 2019), but still
need to keep supporting C<costarica> for a while in order to give API users
enough time to switch over.

This should be removed once we drop supporting C<costarica>.

=over 4

=item * C<$req_storage> - JSON message containing a C<landing_company> field

=back

=cut

sub map_landing_company {
    my ($c, $req_storage) = @_;

    for my $lc (qw(landing_company landing_company_details)) {
        if (exists $req_storage->{args}->{$lc} && $req_storage->{args}->{$lc} =~ s/^costarica$/svg/) {
            stats_inc('bom_websocket_api.v_3.costarica_request', {tags => [$req_storage->{name}, 'app_id:' . ($c->app_id // 'undef')]});
        }
    }

    return;
}

1;
