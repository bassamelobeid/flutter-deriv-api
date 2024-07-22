package BOM::Service::User::Status::Anonymize;

use strict;
use warnings;
no indirect;
use Scalar::Util qw(blessed looks_like_number);
use List::Util   qw(first any all uniq);

use BOM::Service;
use BOM::Service::Helpers;

=head1 NAME

BOM::Service::User::Status::Anonymize

=head1 DESCRIPTION

This package provides methods anonymize a user

=cut

=head2 anonymize_allowed

Determines if the user is valid to anonymize or not.

Returns anonymize_allowed = 1 if the user is valid to anonymize
Returns 0 otherwise

=cut

sub anonymize_allowed {
    my ($request) = @_;
    my $user      = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $allowed   = 0;

    my @clients = $user->clients(
        include_disabled   => 1,
        include_duplicated => 1,
    );

    # filter out virtual clients
    my $real_clients = first { not $_->is_virtual } @clients;

    if ($real_clients) {
        my $result = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector',
            }
        )->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT users.ck_user_valid_to_anonymize(?)', undef, $user->id);
            });
        $allowed = $result->{ck_user_valid_to_anonymize} ? 1 : 0;
    } else {
        # The standard anonymization rules don't apply for clients with no real money accounts. They can be anonymized at any time.
        $allowed = 1;
    }

    return {
        status              => 'ok',
        command             => $request->{command},
        $request->{command} => $allowed
    };
}

=head2 anonymize_status

Determines if the user is valid to anonymize or not.

Returns anonymize_status = 1 if the user is already anonymized
Returns 0 otherwise

=cut

sub anonymize_status {
    my ($request) = @_;
    my $user      = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $status    = $user->{email} =~ /\@deleted\.binary\.user$/ ? 1 : 0;

    return {
        status              => 'ok',
        command             => $request->{command},
        $request->{command} => $status,
    };
}

=head2 anonymize_user

Takes a request hash reference which should contain user_id. Will call the stored procedure to anonymize the user.

=over 4

=item * Input: Hash reference (request)

=item * Return: Hash reference (response)

=back
=cut

sub anonymize_user {
    my ($request) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to anonymize_user not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    my $user   = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});

    # Seriously don't ask why the user anonymization is done by the client loginid, something
    # something legacy code. We should rework the stored procedure to take the user_id instead.
    my $result = $user->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM users.user_anonymization(?)", {Slice => {}}, $client->loginid);
        });

    my @clients = map { $_->{v_loginid} } @$result;

    return {
        status  => 'ok',
        command => $request->{command},
        clients => \@clients,
    };
}

1;
