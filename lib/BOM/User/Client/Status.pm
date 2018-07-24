package BOM::User::Client::Status;

use strict;
use warnings;
use Moose;

use List::Util qw/uniqstr/;

has client_loginid => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has dbic => (
    is       => 'ro',
    isa      => 'DBIx::Connector',
    required => 1,
);

=head2 all

Returns a list containing the client statuses currently enabled for this client

e.g. $client->status->all();

=cut

sub all {
    my ($self) = @_;
    my $loginid = $self->client_loginid;

    my $list = $self->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref('SELECT * FROM betonmarkets.get_client_status_list_all(?)', undef, $loginid);
        });

    return @$list;
}

=head2 visible

Returns a list containing the client statuses currently enabled for this client

e.g. $client->status->visible();

=cut

sub visible {
    my ($self) = @_;
    my $loginid = $self->client_loginid;

    my $list = $self->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref('SELECT * FROM betonmarkets.get_client_status_list_visible(?)', undef, $loginid);
        });

    return @$list;
}

=head2 get

Get is used to check if a client has a particular status_code assigned.
Takes one argument:

=over 4

=item * status_code

=back

    If not, undef is returned.
    If yes, a hashref is returned containing the keys:

=over 4

=item * staff_name

=item * reason

=item * last_modified_date

=back

=cut

sub get {
    my ($self, $status_code) = @_;
    my $loginid = $self->client_loginid;
    die 'status_code is required' unless $status_code;

    my $record = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM betonmarkets.get_client_status(?,?)', undef, $loginid, $status_code);
        });

    return $record;
}

=head2 set

Set is used to assign a status_code to the associated client.
Returns true if successful, or dies.

Takes three arguments:

=over 4

=item * status_code

=item * staff_name (optional)

=item * reason (optional)

=back

=cut

sub set {
    my ($self, $status_code, $staff_name, $reason) = @_;
    my $loginid = $self->client_loginid;
    die 'status_code is required' unless $status_code;

    $self->dbic->run(
        ping => sub {
            $_->do('SELECT betonmarkets.set_client_status(?,?,?,?)', undef, $loginid, $status_code, $staff_name, $reason);
        });

    return 1;
}

=head2 clear

Clear is used to unassign a status_code from the associated client.
Returns true if successful, or dies.

Takes one argument:

=over 4

=item * status_code

=back

=cut

sub clear {
    my ($self, $status_code) = @_;
    my $loginid = $self->client_loginid;
    die 'status_code is required' unless $status_code;

    $self->dbic->run(
        ping => sub {
            $_->do('SELECT betonmarkets.clear_client_status(?,?)', undef, $loginid, $status_code);
        });

    return 1;
}

=head2 multi_set_clear

Multi set/clear is used to do multiple assignments and unassignments on the associated client,
    all as one single database transaction.
Returns true if successful, or dies.

Takes one argument, a hashref containg the following keys (all optional)

=over 4

=item * set: arrayref containg list of status codes to set

=item * clear: arrayref containg list of status codes to clear

=item * staff_name: Staff name associated with the set operations

=item * reason: Reason name associated with the set operations

=back

=cut

sub multi_set_clear {
    my ($self, $args) = @_;
    my $codes_to_set   = $args->{set}        // [];
    my $codes_to_clear = $args->{clear}      // [];
    my $staff_name     = $args->{staff_name} // '';
    my $reason         = $args->{reason}     // '';
    my $loginid        = $self->client_loginid;

    my @all = (@$codes_to_set, @$codes_to_clear);
    die 'status_codes are required' unless @all;
    die 'All specified status_codes must be unique' if @all != uniqstr @all;

    $self->dbic->txn(
        ping => sub {
            my $dbh = $_;
            for (@$codes_to_set) {
                $dbh->do('SELECT betonmarkets.set_client_status(?,?,?,?)', undef, $loginid, $_, $staff_name, $reason);
            }
            for (@$codes_to_clear) {
                $dbh->do('SELECT betonmarkets.clear_client_status(?,?)', undef, $loginid, $_);
            }
        });

    return 1;
}

=head2 is_login_disallowed

e.g. $client->status->is_login_disallowed();

=cut

sub is_login_disallowed {
    my ($self) = @_;
    my $loginid = $self->client_loginid;

    my @res = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.get_client_status_is_login_disallowed(?)', undef, $loginid);
        });

    return $res[0];
}

1;
