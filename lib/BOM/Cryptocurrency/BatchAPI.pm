package BOM::Cryptocurrency::BatchAPI;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Cryptocurrency::BatchAPI - Batch request helper

=head1 SYNOPSIS

    my $batch = BOM::Cryptocurrency::BatchAPI->new();

    # Adding request to the batch, id is auto-generated
    my $address_request_id = $batch->add_request({ action => 'address/validate', body => {} });

    # Adding request to the batch along with an id
    my $list_request_id    = 'tx_list';
    $batch->add_request({ id => $list_request_id, action => 'transaction/get_list', body => {}, depends_on => [$address_request_id] });

    # Processing the batch
    my $all_responses = $batch->process();

    # Retrieving the responses
    my $all_responses    = $batch->get_response();
    my $address_response = $batch->get_response($address_request_id)->[0];

=head1 DESCRIPTION

A helper class to create, validate, and process batch requests.

=cut

use Clone qw(clone);
use Data::UUID;

use BOM::CTC::API::Batch;

=head2 new

Creates a new instance. Doesn't accept any parameters.

    my $batch = BOM::Cryptocurrency::BatchAPI->new();

=cut

sub new {
    my $class = shift;

    my $self = bless {
        requests => [],
        id_list  => {},
    }, $class;

    return $self;
}

=head2 add_request

Adds a request to the current batch.

Receives the following named parameters:

=over 4

=item * C<id>         - string (optional)   Unique identifier for this request in the batch. If not provided, a new C<id> will be automatically generated

=item * C<action>     - string (required)   The action of the request, in the format of C<category/method>, all lowercase

=item * C<body>       - hashref (optional)  Body of the request

=item * C<depends_on> - arrayref (optional) List of B<existing> C<id> in the current batch

=back

Returns the C<id> of the added request. Dies in case of error.

=cut

sub add_request {
    my ($self, %args) = @_;

    $self->_validate_request(%args);

    $args{id} //= $self->_generate_new_id();
    $self->{id_list}{$args{id}} = 1;

    push @{$self->{requests}}, {%args};

    return $args{id};
}

=head2 process

Process the requests of the current batch.

=over 4

=item * C<@ids> - Optional. The list of C<id> to return the response of.

=back

Returns an arrayref containing all the responses or the error.

=cut

sub process {
    my ($self) = @_;

    die 'There is no request in the batch, please use "add_request()".'
        unless $self->{requests}->@*;

    my $response = BOM::CTC::API::Batch::process({
        requests => $self->{requests},
    });

    if ($response->{error}) {
        $self->{response_error} = $response->{error};
        return clone $response->{error};
    }

    $self->{responses} = $response->{responses};
    return clone $self->{responses};
}

=head2 get_response

Get the responses of a processed batch.

=over 4

=item * C<@ids> - Optional. The list of C<id> to return the response of.

=back

In case the result of C<process()> was a success, returns an arrayref
containing either all the responses or those matching the passed C<@ids>
otherwise, returns the received error.

=cut

sub get_response {
    my ($self, @ids) = @_;

    return clone $self->{response_error} if $self->{response_error};

    die 'There is no response yet. Maybe you forgot to invoke "process()" on the batch.'
        unless $self->{responses};

    return clone $self->{responses} unless @ids;

    my %id_lookup = map { $_ => 1 } @ids;
    return clone [grep { exists $id_lookup{$_->{id}} } $self->{responses}->@*];
}

=head2 _generate_new_id

Generates a new C<id> to be used for the next request of this batch.
Default format of auto-generated C<id> is C<auto-%02d-UUID>.

=cut

sub _generate_new_id {
    my ($self) = @_;
    return sprintf('auto-%02d-%s', $self->{requests}->@* + 1, Data::UUID->new()->create_str());
}

=head2 _id_exists

Checks whether the provided C<id> already used by a request in the current batch.

=over 4

=item * C<$id> - The C<id> to check the existence of.

=back

Returns 1 if already exists, otherwise 0.

=cut

sub _id_exists {
    my ($self, $id) = @_;
    return exists $self->{id_list}{$id};
}

=head2 _validate_request

Validate the request arguments.

=over 4

=item * C<%args> - Named parameters of the request to validate

=back

Dies with the error message in case of validation failure.

=cut

sub _validate_request {
    my ($self, %args) = @_;

    my $id = delete $args{id};
    die sprintf('"id" with the same value already exists: %s', $id)
        if ($id and $self->_id_exists($id));

    my $action = delete $args{action};
    die '"action" is required but it is missing'
        unless $action;
    die sprintf('"action" should be in the format of "category/method": %s', $action)
        if $action !~ /^[a-z]+\/[a-z_]+$/;

    my $body = delete $args{body};
    die '"body" should be hashref'
        if ($body and ref $body ne 'HASH');

    if (my $depends_on = delete $args{depends_on}) {
        die '"depends_on" should be arrayref'
            if (ref $depends_on ne 'ARRAY');
        if (my @nonexistent_ids = grep { !$self->_id_exists($_) } $depends_on->@*) {
            die sprintf('"depends_on" contains nonexistent ids: %s', (join ', ', @nonexistent_ids));
        }
    }

    if (my @extra_keys = sort keys %args) {
        die sprintf('Extra keys are not permitted: %s', (join ', ', @extra_keys));
    }
}

1;
