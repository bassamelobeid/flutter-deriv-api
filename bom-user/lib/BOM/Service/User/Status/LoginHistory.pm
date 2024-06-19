package BOM::Service::User::Status::LoginHistory;

use strict;
use warnings;
no indirect;
use Scalar::Util qw(blessed looks_like_number);

use BOM::Service;
use BOM::Service::Helpers;

=head1 NAME

BOM::Service::User::Status::LoginHistory

=head1 DESCRIPTION

This package provides methods to get and add login history for a user.

=head2 get_login_history

Takes a request hash reference which should contain user_id, limit, and show_backoffice. It
retrieves the login history for the user from the database, removes irrelevant fields, and
returns a hash reference containing the status, command, and login history.

=over 4

=item * Input: Hash reference (request)

=item * Return: Hash reference (response)

=back
=cut

sub get_login_history {
    my ($request) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to BOM::Service::get_login_history not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $user_id         = $request->{user_id};
    my $limit           = $request->{limit};
    my $show_backoffice = $request->{show_backoffice};

    my $user = BOM::Service::Helpers::get_user_object($user_id, $request->{context}->{correlation_id});

    my $sql           = "select * from users.get_login_history(?,?,?) limit ?";    ## SQL safe($limit)
    my $login_history = $user->dbic(operation => 'replica')->run(
        fixup => sub {
            $_->selectall_arrayref($sql, {Slice => {}}, $user->{id}, 'desc', $show_backoffice, $limit);
        });

    # Delete 'id' and 'binary_user_id' fields from each object, not relevant
    foreach my $entry (@$login_history) {
        delete $entry->{id};
        delete $entry->{binary_user_id};
    }

    return {
        status        => 'ok',
        command       => $request->{command},
        login_history => \@$login_history,
    };
}

=head2 add_login_history

This subroutine is not yet implemented. It is expected to take a request hash reference, an attribute, and a value, and add a login history entry for the user.

=over 4

=item * Input: Hash reference (request), Scalar (attribute), Scalar (value)

=back

=cut

sub add_login_history {
    my ($request, $attribute, $value) = @_;

    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to BOM::Service::set_login_history not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $user = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    die "get_login_history: Not implemented";
}

1;
