package BOM::Product::Contract::Category;

=head1 NAME

BOM::Product::Contract::Category

=head1 SYNOPSYS

    my $contract_category = BOM::Product::Contract::Category->new("callput");

=head1 DESCRIPTION

This class represents available contract categories.

=head1 ATTRIBUTES

=cut

use Carp;
use Moose;
use YAML::XS qw(LoadFile);
use namespace::autoclean;
use BOM::Platform::Context qw(localize);

my $category_config = LoadFile('/home/git/regentmarkets/bom/config/files/contract_categories.yml');

has code => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 code

Our internal code (callput, touchnotouch, ...)

=head2 display_name

What is the name of this bet as an action?

=head2 display_order

In which order should these be preferred for display in a UI?

=head2 explanation

How do we explain this contract category to a client?

=cut

has [qw(display_name display_order explanation supported_expiries)] => (
    is => 'ro',
);

has [qw(allow_forward_starting two_barriers)] => (
    is      => 'ro',
    default => 0,
);

has available_types => (
    is      => 'ro',
    default => sub { [] },
);

has offer => (
    is      => 'ro',
    default => 1,
);

has is_path_dependent => (
    is      => 'ro',
    default => 0,
);

has supported_start_types => (
    is      => 'ro',
    default => sub { ['spot'] },
);

=head1 METHODS

=head2 translated_display_name

Returns the translated version of display_name.

=cut

sub translated_display_name {
    my $self = shift;

    return unless ($self->display_name);
    return localize($self->display_name);
}

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    croak 'Cannot build BOM::Product::Contract::Category without code'
        unless $_[0];

    my %args   = ref $_[0] eq 'HASH' ? %{$_[0]} : (code => $_[0]);
    my $config = $category_config;
    my $wanted = $config->{$args{code}};

    return $class->$orig(%args) unless $wanted;
    return $class->$orig(%args, %$wanted);
};

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

RMG Tech (Malaysia) Sdn Bhd

=head1 LICENSE AND COPYRIGHT

Copyright 2013- RMG Technology (M) Sdn Bhd

=cut

