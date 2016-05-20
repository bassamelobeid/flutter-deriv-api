package BOM::Product::Contract::Strike::Digit;

use Moose;
use namespace::autoclean;
use Scalar::Util qw(looks_like_number);
use BOM::Platform::Context qw(localize);

extends 'BOM::Product::Contract::Strike';

has '+basis_tick' => (
    required => 0,
);

has '+supplied_barrier' => (
    writer => '_set_supplied_barrier',
);

sub BUILD {
    my $self = shift;

    if (not(looks_like_number($self->supplied_barrier) and $self->supplied_barrier =~ /^[0-9]$/)) {
        $self->add_errors({
            severity          => 110,
            message           => 'supplied barrier for digits is undefined',
            message_to_client => localize('We could not process this contract at this time.'),
        });
        # setting supplied barrier to zero
        $self->_set_supplied_barrier(0);
    }

    return;
}

override _build_supplied_type => sub {
    return 'digit';
};

override _build_as_relative => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_as_absolute => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_as_difference => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_pip_difference => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override for_shortcode => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override display_text => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

__PACKAGE__->meta->make_immutable;
1;
