package BOM::Event::Actions::Client::Status;

use strict;
use warnings;

use BOM::User::Client;
use BOM::Event::Utility qw(exception_logged);
use Syntax::Keyword::Try;
use Log::Any qw($log);

=head1 NAME

BOM::Event::Actions::Client

=head1 DESCRIPTION

Provides handlers for client-related events.

=cut

no indirect;

=head2 execute_set_status

Handles requests triggered form the sideoffce to set client account status 

=over 4

=item * C<loginid> - required. Login id of the client.

=item * C<username> - required. Slack username for the CS agent that made the request

=item * C<status> - required. Status that need to be added/updated for client.

=item * C<reason> - required. a predefined reason that will be set/updated for the status

=back

=cut

sub execute_set_status {
    my ($args) = @_;
    my $status = $args->{status} // die 'Need a status';

    my $client = BOM::User::Client->new({loginid => $args->{loginid}})
        or die 'Could not instantiate client for login ID ' . $args->{loginid};
    try {
        #shouldn't override status reason if already set, and we cannot disable account with open contracts.
        return 0 if $client->status->$status || ($status eq 'disabled' && @{$client->get_open_contracts});

        $client->status->setnx($status, $args->{username}, $args->{reason});
        return 1;
    } catch ($error) {
        $log->errorf("Error in adding status %s for account %s: %s", $status, $client->loginid, $error);
        exception_logged();
    }
}

=head2 execute_remove_status

Handles requests triggered form the sideoffce to remove client account status 

=over 4

=item * C<loginid> - required. Login id of the client.

=item * C<status> - required. Status that need to be removed for client.

=back

=cut

sub execute_remove_status {
    my ($args) = @_;
    my $client = BOM::User::Client->new({loginid => $args->{loginid}})
        or die 'Could not instantiate client for login ID ' . $args->{loginid};
    try {
        my $client_status_cleaner_method_name = 'clear_' . $args->{status};
        $client->status->$client_status_cleaner_method_name;
        return 1;
    } catch ($error) {
        $log->errorf("Error in removing status %s for account %s: %s", $args->{status}, $client->loginid, $error);
        exception_logged();
    }
}

1;
