package BOM::User::Client::ProofOfOwnership;

use strict;
use warnings;
use Moo;

use JSON::MaybeXS qw(encode_json decode_json);
use List::Util qw(any all);

=head1 NAME

BOM::User::Client::ProofOfOwnership - A class that manages the client POO and related logic.

=cut

=head2 client

The C<BOM::User::Client> instance

=cut

has client => (
    is       => 'ro',
    required => 1,
    weak_ref => 1,
);

=head2 create

Creates a new POO in the I<pending> status.

It takes the following arguments as hashref:

=over 4

=item * C<payment_method> - the payment method to request POO

=item * C<payment_method_identifier> - the identifier of the payment method we are requesting POO

=back

Returns the new POO record.

=cut

sub create {
    my ($self, $args) = @_;

    my ($payment_method, $payment_method_identifier) = @{$args}{qw/payment_method payment_method_identifier/};

    my $proof_of_ownership = $self->client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.create_proof_of_ownership(?, ?, ?)',
                undef,           $self->client->loginid,
                $payment_method, $payment_method_identifier,
            );
        });

    return $self->_normalize($proof_of_ownership);
}

=head2 full_list

The full list of POO for the current client.

=cut

has 'full_list' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_full_list',
    clearer => '_clear_full_list',
);

=head2 _build_full_list

Returns the full list of POO for the current client, this is the same as calling I<list> without args. 

This one is also cached for convenience.

=cut

sub _build_full_list {
    my ($self) = shift;

    return $self->list();
}

=head2 list

Retrieves the list of proof of ownerships that belong to the client.

It takes the folllowing arguments as hashref:

=over 4

=item * C<id> - (optional) a proof of ownership id

=item * C<status> - (optioanl) the status of the proof of ownership being requested.

=back

Returns an arrayref of POOs.

=cut

sub list {
    my ($self, $args) = @_;

    my ($id, $status) = @{$args}{qw/id status/};

    my $list_of_poo = $self->client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM betonmarkets.list_proof_of_ownership(?, ?, ?)',
                {Slice => {}},
                $self->client->loginid,
                $id, $status,
            );
        });

    return [map { $self->_normalize($_) } $list_of_poo->@*];
}

=head2 fulfill

Changes the status of the POO to I<uploaded>.

It takes the following arguments as hashref:

=over 4

=item * C<id> - the id of the POO being updated.

=item * C<payment_method_details> - a hashref with unspecific POO details.

=item * C<client_authentication_document_id> - the ID of the related document uploaded.

=back

Returns the updated POO record.

=cut

sub fulfill {
    my ($self, $args) = @_;

    my ($id, $payment_method_details, $client_authentication_document_id) = @{$args}{qw/id payment_method_details client_authentication_document_id/};

    $payment_method_details = encode_json($payment_method_details // {});

    my $proof_of_ownership = $self->client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.fulfill_proof_of_ownership(?, ?, ?, ?)',
                undef, $id, $self->client->loginid,
                $payment_method_details, $client_authentication_document_id,
            );
        });

    die sprintf("Cannot fulfill proof of ownership %d", $id) unless $proof_of_ownership;

    return $self->_normalize($proof_of_ownership);
}

=head2 _normalize

Normalizes the POO structure, removes the poo prefix, decodes json data, etc.

=cut

sub _normalize {
    my (undef, $poo) = @_;

    $poo->{documents} //= [];
    $poo->{payment_method_details} = decode_json($poo->{payment_method_details} // '{}');

    return $poo;
}

=head2 needs_verification

Returns a flag which determines whether the client requires POO verification.

Is not needed when current status is: I<verified> or I<pending> or empty POO list.

A list can be optionally passed to avoid DB hit.

=cut

sub needs_verification {
    my ($self, $list) = @_;

    $list //= $self->full_list();

    my $status = $self->status($list);

    return 0 unless @$list;

    return 0 if $status eq 'pending';

    return 0 if $status eq 'verified';

    return 1;
}

=head2 status

Get the current POO status of the client.

Could be: I<pending>, I<none>, I<rejected> or I<verified>

=over 4

=item * I<pending>: the client has at least one POO pending of review

=item * I<none>: nothing has been uploaded

=item * I<verified>: all of the POOs were verified

=item * I<rejected>: one of the POOs were rejected

=back

A list can be optionally passed to avoid DB hit.

=cut

sub status {
    my ($self, $list) = @_;

    $list //= $self->full_list();

    return 'none' unless @$list;

    return 'verified' if all { $_->{status} eq 'verified' } $list->@*;

    return 'rejected' if any { $_->{status} eq 'rejected' } $list->@*;

    # this might cause head scratching:
    # the db poo `pending` status means the client has not yet uploaded
    # the db poo `uploaded` status really means we are waiting for review (of the uploaded doc)
    return 'pending' if any { $_->{status} eq 'uploaded' } $list->@*;

    return 'none';
}

=head2 verify

Flags the given proof of owneship document as `verified`.

It takes the folllowing arguments as hashref:

=over 4

=item * C<id> - (optional) a proof of ownership id

=back

Returns the updated POO record.

=cut

sub verify {
    my ($self, $args) = @_;
    my $id = $args->{id};

    my $proof_of_ownership = $self->client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM betonmarkets.verify_proof_of_ownership(?, ?)', undef, $id, $self->client->loginid);
        });

    die sprintf("Cannot verify proof of ownership %d", $id) unless $proof_of_ownership;

    return $self->_normalize($proof_of_ownership);
}

=head2 reject

Flags the given proof of owneship document as `rejected`.

It takes the folllowing arguments as hashref:

=over 4

=item * C<id> - (optional) a proof of ownership id

=back

Returns the updated POO record.

=cut

sub reject {
    my ($self, $args) = @_;
    my $id = $args->{id};

    my $proof_of_ownership = $self->client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM betonmarkets.reject_proof_of_ownership(?, ?)', undef, $id, $self->client->loginid);
        });

    die sprintf("Cannot reject proof of ownership %d", $id) unless $proof_of_ownership;

    return $self->_normalize($proof_of_ownership);
}

1;
