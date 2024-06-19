package BOM::Product::Exception;

use strict;
use warnings;
use Moo;

use BOM::Product::Static qw(get_error_mapping);

my $ERR = get_error_mapping();

=head1 NAME

BOM::Product::Exception - A class to handle exception.

=head1 SYNOPSIS

    use BOM::Product::Exception;

    BOM::Product::Exception->throw(error_code => 'AlreadyExpired');

=cut

=head2 error_code

A string representation of errors in BOM::Product::Static

=cut

has error_code => (
    is       => 'ro',
    required => 1,
);

=head2 error_args

Arguments to the error message. Excepts an array reference.

=cut

has error_args => (
    is      => 'ro',
    default => sub { [] },
);

=head2 details

An arbitrary optional HashRef to pass the error details.

=cut

has details => (
    is       => 'ro',
    required => 0,
);

sub BUILD {
    my $self = shift;

    my $error_message = $ERR->{$self->error_code};
    die 'Unknown error_code' unless $error_message;

    my $expected_args = () = $error_message =~ /\[_\d+\]/g;

    die "Number of argument(s) expected for " . $self->error_code . " [$expected_args]. Error message: $error_message"
        if $expected_args != @{$self->error_args};

    return;
}

=head2 throw

throw exception with BOM::Product:::Exception

=cut

sub throw {
    my ($class, %args) = @_;

    die $class->new(%args);
}

=head2 message_to_client

Return an array reference of message to client, followed by its argument(s) if any.

=cut

sub message_to_client {
    my $self = shift;

    return [$ERR->{$self->error_code}, @{$self->error_args}];
}

1;
