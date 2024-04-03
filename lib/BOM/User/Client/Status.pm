package BOM::User::Client::Status;

use strict;
use warnings;
use Moo;

use List::Util qw/uniqstr any/;
use namespace::clean;
use Class::Method::Modifiers qw( install_modifier );
use Carp                     qw( croak );
use Array::Utils             qw(array_minus);

use BOM::Config;
use Business::Config::Account;

has client_loginid => (
    is       => 'ro',
    required => 1,
);

has dbic => (
    is       => 'ro',
    required => 1,
);

use constant STATUS_CODES => qw(
    age_verification  cashier_locked  disabled  unwelcome  withdrawal_locked
    mt5_withdrawal_locked  ukgc_funds_protection  financial_risk_approval
    crs_tin_information  max_turnover_limit_not_set
    professional_requested  professional  professional_rejected  tnc_approval
    migrated_single_email  duplicate_account
    require3ds  skip_3ds  ok  ico_only  allowed_other_card  can_authenticate
    social_signup  trusted  pa_withdrawal_explicitly_allowed  financial_assessment_required
    address_verified  no_withdrawal_or_trading no_trading  allow_document_upload internal_client
    closed  transfers_blocked  shared_payment_method  personal_details_locked
    allow_poi_resubmission  allow_poa_resubmission migrated_universal_password
    poi_name_mismatch crypto_auto_reject_disabled crypto_auto_approve_disabled potential_fraud
    deposit_attempt df_deposit_requires_poi smarty_streets_validated trading_hub poi_dob_mismatch
    allow_poinc_resubmission cooling_off_period poa_address_mismatch poi_poa_uploaded eligible_counterparty partner
    allow_duplicate_signup poi_duplicated_documents selfie_pending selfie_verified selfie_rejected resident_self_declaration
);

use constant STATUS_COPY_CONFIG => Business::Config::Account->new()->statuses_copied_from_siblings();

# codes that are about to be dropped
my @deprecated_codes = qw(
    proveid_requested proveid_pending
);

use constant STATUS_CODE_HIERARCHY => BOM::Config::status_hierarchy()->{hierarchy};

=head2 _build_parent_map

Function to build a parent map from the given hierarchy.
Input tree: {
    'parent1' => [
        'child1',
        'child2',
        ...
    ],
    'parent2' => [
        'child3',
        'child4',
        ...
    ],
    ...
}

Output map: {
    'child1' => 'parent1',
    'child2' => 'parent1',
    'child3' => 'parent2',
    'child4' => 'parent2',
    ...
}

Returns a hashref containing the parent map

=over 4

=item * tree: hashref, tree to build parent map from

=back

=cut

sub _build_parent_map {
    my ($hierarchy) = @_;

    my %parent_map;

    foreach my $parent_status (keys %$hierarchy) {
        foreach my $child_status (@{$hierarchy->{$parent_status}}) {
            $parent_map{$child_status} = $parent_status;
        }
    }

    return \%parent_map;
}

use constant REVERSE_STATUS_CODE_HIERARCHY => _build_parent_map(STATUS_CODE_HIERARCHY);

for my $code (STATUS_CODES) {
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

        my $result = $self->_clear($code);
        # 'closed' is dependent on 'disabled', so it should be cleared along with 'disabled'.
        $result &&= $self->clear_closed if $code eq 'disabled';

        return $result;
    };
}

=head2 children

Returns an array containing the client statuses that are children of the given status code

=over 4

=item * status_code

=back

=cut

sub children {
    my ($status_code) = @_;
    my $children = STATUS_CODE_HIERARCHY->{$status_code} // [];
    return $children->@*;
}

=head2 parent

Returns the status code that is the parent of the given status code

=over 4

=item * status_code

=back

=cut

sub parent {
    my ($status_code) = @_;
    return REVERSE_STATUS_CODE_HIERARCHY->{$status_code};
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
Returns true if succesful and status code did not exist before
Returns false if succesful and status code existed before, or dies.

Takes four arguments:

=over 4

=item * status_code

=item * staff_name (optional)

=item * reason (optional)

=item * set_if_not_exist_flag (optional)

=back

=cut

sub set {
    my ($self, $status_code, $staff_name, $reason, $allow_existing) = @_;
    my $loginid = $self->client_loginid;
    die 'status_code is required' unless $status_code;

    my $status_code_exists = defined $self->_get($status_code);
    my @statuses_to_apply  = ($status_code);
    my $parent             = parent($status_code);
    if ($parent) {
        push @statuses_to_apply, $parent;
    }

    my $dbh = $self->dbic->dbh;

    # Since parent can be applied already, we would have allow_existing as 1 for parent application
    my @allow_existing = map { $_ eq $status_code ? $allow_existing : 1 } @statuses_to_apply;

    my $stmt = $dbh->prepare(
        'SELECT betonmarkets.set_client_status($1, x.code, $3 , $4, x.allow_existing) FROM unnest($2::TEXT[], $5::BOOLEAN[]) AS x(code, allow_existing)'
    );
    my $result = $stmt->execute($loginid, \@statuses_to_apply, $staff_name, $reason, \@allow_existing);

    if ($result) {
        foreach (@statuses_to_apply) {
            delete $self->{$_};
        }

        $self->_clear_composite_cache_elements();
        return !$status_code_exists;
    }

    return $result;
}

=head2 setnx

Only set the status_code if it does not already exist.

Takes three arguments:

=over 4

=item * status_code

=item * staff_name (optional)

=item * reason (optional)

=back

Returns L<BOM::User::Client::Status::set>

=cut

sub setnx {
    my ($self, $status_code, $staff_name, $reason) = @_;
    return $self->set($status_code, $staff_name, $reason, 1);
}

=head2 upsert

This sub guarantees the reason persisted will be the one you specify.
Does nothing if the reason is not updated.
Note statuses don't have a proper update method, what we call update here is `clear + set again`.
Takes three arguments:

=over 4

=item * status_code

=item * staff_name (optional)

=item * reason (optional)

=back

Returns L<BOM::User::Client::Status::set>

=cut

sub upsert {
    my ($self, $status_code, $staff_name, $reason) = @_;
    my $current = $self->_get($status_code);

    # Need to clear the status if the reasons don't match
    if ($current) {
        if (($current->{reason} // '') ne ($reason // '')) {
            my $method = "clear_$status_code";
            $self->$method;
        }
    }

    # Note setnx has no effect if the status is already there
    return $self->setnx($status_code, $staff_name, $reason);
}

=head2 reason

Safely gets the current reason for a given status.

It takes the following arguments:

=over 4

=item * status_code

=back

Returns the current reason for the C<status_code> or undef.

=cut

sub reason {
    my ($self, $status_code) = @_;

    my $status = $self->$status_code // return undef;

    $status = {} unless ref($status) eq 'HASH';

    return $status->{reason};
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

    my @statuses_to_clear = ($status_code);
    my @children          = children($status_code);

    if (scalar @children) {
        push @statuses_to_clear, @children;
    }

    my $dbh = $self->dbic->dbh;

    my $stmt   = $dbh->prepare('SELECT betonmarkets.clear_client_status($1, x.code) FROM unnest($2::TEXT[]) AS x(code)');
    my $result = $stmt->execute($loginid, \@statuses_to_clear);

    if ($result) {
        foreach (@statuses_to_clear) {
            delete $self->{$_};
        }
    }

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

    delete @{$list}{@deprecated_codes};

    #populate attributes for object
    @{$self}{STATUS_CODES()} = ();
    @{$self}{keys %$list} = values %$list;
    return $list;

}

=head2 get_status_config

Gets the config for the given status code

Returns a hashref containing the config for the given status code

=over 4

=item * status_code

=back

=cut

sub get_status_config {
    my $status_code   = shift;
    my $status_config = STATUS_COPY_CONFIG->{config}->{$status_code};
    return $status_config;
}

=head2 can_copy

Checks if the given status code can be copied from client belonging to one broker to another broker, 
based on if system or staff applied it

Returns 1 if it can be copied, 0 otherwise

By default, all statuses can be copied, unless specified in the config

=over 4

=item * status_code

=item * from_broker_code

=item * to_broker_code

=item * applied_by

Only accepts `staff` or `system`

=back

=cut

sub can_copy {
    my ($status_code, $from_broker_code, $to_broker_code, $applied_by) = @_;

    die 'Only accepts staff or system' if $applied_by ne 'staff' && $applied_by ne 'system';

    my $status_config = get_status_config($status_code);
    return 0 unless $status_config;

    my $broker_concat = $from_broker_code . '_' . $to_broker_code;

    return 0 unless $status_config->{$broker_concat};

    return 0 unless defined $status_config->{$broker_concat}->{'applied_by'}->{$applied_by};

    return $status_config->{$broker_concat}->{'applied_by'}->{$applied_by};

}

=head2 get_all_statuses_to_copy_from_siblings

Returns all the statuses that can be copied from the siblings

Returns an array ref of status codes

=cut

sub get_all_statuses_to_copy_from_siblings {
    my $config                  = STATUS_COPY_CONFIG->{config};
    my $duplicate_only_statuses = get_duplicate_only_statuses_to_copy_from_siblings();
    my @all_statuses            = keys(%$config);
    return [array_minus(@all_statuses, @$duplicate_only_statuses)];

}

=head2 get_duplicate_only_statuses_to_copy_from_siblings

Returns all the statuses that can be copied from the siblings only if the sibling is a duplicate

Returns an array ref of status codes

=cut

sub get_duplicate_only_statuses_to_copy_from_siblings {
    my $config = STATUS_COPY_CONFIG;
    return $config->{duplicate_only} // [];

}

1;
