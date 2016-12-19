package Binary::WebSocketAPI::v3::Wrapper::Authorize;

use strict;
use warnings;

sub logout_success {
    my ($c, $rpc_response) = @_;
    my %stash;
    @stash{qw/ loginid email token token_type account_id currency landing_company_name /} = ();
    $c->stash(%stash);
    return;
}

=head2 authorize_success

Called after authorize so we can check for missing C<app_id> and log some details.

This is a temporary function that should be removed once the C<app_id> enforcement is in place.

=cut

my %recorded_clients;

sub authorize_success {
    my ($c, $rpc_response) = @_;

    # Collect some information about this client if they didn't use an app_id,
    # but only log the warning once per unique case.
    my @param = ($c->stash('account_id'), $c->country_code, $c->stash('client_ip'), $c->stash('user_agent'));
    my $key = join "\0", @param;
    warn sprintf "[Missing app_id] Client %s from %s (%s), UA %s\n", @param
        unless $c->stash('source')
        or $recorded_clients{$key}++;

    return;
}

1;
