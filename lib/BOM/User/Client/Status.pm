package BOM::User::Client::Status;

use strict;
use warnings;
use Moo;

use List::Util qw/uniqstr any/;
use namespace::clean;
use Class::Method::Modifiers qw( install_modifier );
has client_loginid => (
    is       => 'ro',
    required => 1,
);

has dbic => (
    is       => 'ro',
    required => 1,
);

my @status_codes = qw(
    age_verification cashier_locked  disabled  unwelcome  withdrawal_locked
    mt5_withdrawal_locked  ukgc_funds_protection  financial_risk_approval
    crs_tin_information  max_turnover_limit_not_set
    professional_requested  professional professional_rejected  tnc_approval
    migrated_single_email  duplicate_account  proveid_pending  proveid_requested
    require3ds  skip_3ds  ok  ico_only  allowed_other_card  can_authenticate
    social_signup  trusted pa_withdrawal_explicitly_allowed
    address_verified no_withdrawal_or_trading allow_document_upload
);

for my $code (@status_codes) {
    has $code => (
        is      => 'ro',
        lazy    => 1,
        builder => 1,
        clearer => 1
    );
    no strict 'refs';
    *{__PACKAGE__ . "::_build_$code"} = sub {
        my $self = shift;
        $self->_get($code);
    };

    after "clear_$code" => sub {
        my $self = shift;
        return $self->_clear($code);
    };
}

=head2 all

Returns an arrayref containing the client statuses currently enabled for this client

e.g. $client->status->all;

=cut

has all => (
    is      => 'lazy',
    clearer => '_clear_all',
);

sub _build_all {
    my ($self) = @_;

    my $records          = $self->_get_all_clients_status();
    my @status_code_list = sort keys(%$records);

    return \@status_code_list;
}

=head2 visible

Returns an arrayref containing the client statuses currently enabled for this client
B<Note> There is logic in our code that alters the arrayref returned by this method so be careful if caching these results. 
e.g. $client->status->visible;

=cut

has visible => (
    is      => 'lazy',
    clearer => '_clear_visible',
);

sub _build_visible {
    my ($self) = @_;
    my $loginid = $self->client_loginid;

    my $list = $self->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref('SELECT * FROM betonmarkets.get_client_status_list_visible(?)', undef, $loginid);
        });

    return $list;
}

=head2 is_login_disallowed

e.g. $client->status->is_login_disallowed;

=cut

has is_login_disallowed => (
    is      => 'lazy',
    clearer => '_clear_is_login_disallowed',
);

sub _build_is_login_disallowed {
    my ($self) = @_;
    my $loginid = $self->client_loginid;

    my @res = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.get_client_status_is_login_disallowed(?)', undef, $loginid);
        });

    return $res[0];
}

=head2 set

set is used to assign a status_code to the associated client.
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

    delete $self->{$status_code};
    $self->_clear_composite_cache_elements();

    return 1;
}

=head2 multi_set_clear

Multi set/clear is used to do multiple assignments and unassignments on the associated client,
    all as one single database transaction.
Returns true if successful, or dies.

Takes one argument, a hashref containing the following keys (all optional)

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

    my @all_codes = (@$codes_to_set, @$codes_to_clear);
    die 'status_codes are required' unless @all_codes;
    die 'All specified status_codes must be unique' if @all_codes != uniqstr @all_codes;
    $self->dbic->txn(
        sub {
            for my $status_code (@$codes_to_set) {
                $self->set($status_code, $staff_name, $reason);
            }
            for my $status_code (@$codes_to_clear) {
                my $method = "clear_$status_code";
                $self->$method;
            }
        });

    return 1;
}

=head2 has_any

Method is a predicate to check client has any of the listed statuses

=over 4

=item * @statuses

=back

=cut

sub has_any {
    my ($self, @statuses) = @_;

    my %is_required = map { $_ => 1 } @statuses;

    return any { $is_required{$_} } $self->all->@*;
}

################################################################################

=head1 METHODS - Private

=head2 _clear

_clear is used to unassign a status_code from the associated client in the db table. Intended to be a private
call from clear_statuscode calls
Returns true if successful, or dies.

Takes one argument:

=over 4

=item * status_code

=back

=cut

sub _clear {
    my ($self, $status_code) = @_;
    my $loginid = $self->client_loginid;
    die 'status_code is required' unless $status_code;

    $self->dbic->run(
        ping => sub {
            $_->do('SELECT betonmarkets.clear_client_status(?,?)', undef, $loginid, $status_code);
        });

    $self->_clear_composite_cache_elements();

    return 1;
}

=head2 _get

_get is used to check if a client has a particular status_code assigned.
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

=item * status_code

=back

=cut

sub _get {
    my ($self, $status_code) = @_;
    die 'status_code is required' unless $status_code;
    my $records = $self->_get_all_clients_status();
    return $records->{$status_code};
}

=head2 _clear_composite_cache_elements

=cut

sub _clear_composite_cache_elements {
    my ($self) = @_;
    $self->_clear_all;
    $self->_clear_visible;
    $self->_clear_is_login_disallowed;
    return;
}

=head2 _get_all_client_statuses 

Gets all the clients set status's from the database. 
    Takes No arguments


Returns a hashref of status's and their properties  keyed by the status name 
eg. 
    
    {
        age_verification => {
                staff_name => 'fred', 
                reason => 'blah blah',
                last_modified_date => '2018-01-02 10:00:00',
                status_code => 'age_verification'
                },
        disabled => {
                staff_name => 'fred', 
                reason => 'blah blah',
                last_modified_date => '2018-01-02 10:00:00',
                status_code => 'disabled'
                }
    }


=cut

sub _get_all_clients_status {
    my ($self)  = @_;
    my $loginid = $self->client_loginid;
    my $list    = $self->dbic->run(
        fixup => sub {
            $_->selectall_hashref('SELECT * FROM betonmarkets.get_client_status_all(?)', 'status_code', undef, $loginid);
        });
    #populate attributes for object
    @{$self}{keys %$list} = values %$list;
    return $list;

}
1;
