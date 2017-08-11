package BOM::Product::Exception;

use Moo;

use BOM::Product::Static qw(get_error_mapping);

my $ERR = get_error_mapping();

has error_code => (
    is       => 'ro',
    required => 1,
);

has error_args => (
    is      => 'ro',
    default => sub { [] },
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

sub message_to_client {
    my $self = shift;

    return [$ERR->{$self->error_code}, @{$self->error_args}];
}

1;
