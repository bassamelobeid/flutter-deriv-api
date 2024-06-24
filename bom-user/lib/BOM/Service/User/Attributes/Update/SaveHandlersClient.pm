package BOM::Service::User::Attributes::Update::SaveHandlersClient;

use strict;
use warnings;
no indirect;

use Cache::LRU;
use Time::HiRes qw(gettimeofday tv_interval);

use BOM::Service;
use BOM::Service::Helpers;
use BOM::Service::User::Attributes;
use BOM::Service::User::Attributes::Get;
use BOM::Service::User::Transitional::Password;
use BOM::Service::User::Transitional::SocialSignup;
use BOM::Service::User::Transitional::TotpFields;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Platform::Event::Emitter;

# A word to the wise on Clients objects vs User objects. The Client object appears a full on rose
# object with all the bells and whistles, and so we should use the getters/setters to ensure the
# object is aware of the changes. The User object is a bit of a kludge and in that case the hash
# access is the way to go.

=head2 save_client

This subroutine saves the client object. It first retrieves the client object using the user_id and correlation_id from the request. Then, it attempts to save the client object. If the save operation fails, it throws an error.

=over 4

=item * Input: HashRef (request)

=item * Return: None. If the save operation fails, it throws an error.

=back

=cut

sub save_client {
    my ($request) = @_;
    my $user      = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $client    = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});

    # Save the default client object
    if (not $client->save()) {
        die "Failed to save client " . $client->loginid;
    }

    # TODO - Sometime soon when we have default_client sorted this will no longer be needed
    my @loginids     = ();
    my @failed_saves = ();
    if ($client->is_virtual) {
        # If we have a virtual default client we know there is no real client or need to sync
        push @loginids, $user->bom_virtual_loginid        if $user->bom_virtual_loginid;
        push @loginids, $user->bom_virtual_wallet_loginid if $user->bom_virtual_wallet_loginid;
    } else {
        # Non-virtual and non-external clients
        push @loginids, $user->bom_real_loginids if $user->bom_real_loginids;
    }

    foreach my $loginid (@loginids) {
        my $client_sync = $loginid eq $client->loginid ? $client : BOM::User::Client->new({loginid => $loginid});

        # Copy over the fields
        $client_sync->address_line_1($client->address_line_1);
        $client_sync->address_line_2($client->address_line_2);
        $client_sync->address_city($client->address_city);
        $client_sync->address_state($client->address_state);
        $client_sync->address_postcode($client->address_postcode);
        $client_sync->phone($client->phone);
        $client_sync->place_of_birth($client->place_of_birth);
        $client_sync->date_of_birth($client->date_of_birth);
        $client_sync->citizen($client->citizen);
        $client_sync->salutation($client->salutation);
        $client_sync->first_name($client->first_name);
        $client_sync->last_name($client->last_name);
        $client_sync->account_opening_reason($client->account_opening_reason);
        $client_sync->secret_answer($client->secret_answer);
        $client_sync->secret_question($client->secret_question);
        $client_sync->residence($client->residence);
        $client_sync->financial_assessment($client->financial_assessment);
        $client_sync->latest_environment($request->{context}{environment});

        # Log any failed saves
        push @failed_saves, $loginid if !$client_sync->save();
    }
    if (scalar @failed_saves) {
        die "Failed to save clients: " . join(', ', @failed_saves);
    }
}

=head2 save_client_financial_assessment

This subroutine saves the client financial_assessment object. It first retrieves the client object using the user_id and correlation_id from the request. Then, it attempts to save the object. If the save operation fails, it throws an error.

=over 4

=item * Input: HashRef (request)

=item * Return: None. If the save operation fails, it throws an error.

=back

=cut

sub save_client_financial_assessment {
    my ($request) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    $client->set_financial_assessment($request->{attributes}{client_financial_assessment});
}

1;
