package BOM::System::Host::Role;

use Moose;
use namespace::autoclean;

use List::MoreUtils qw(uniq);
use List::Util qw(first);

has name => (
    is       => 'ro',
    required => 1,
);

=head1 inherits

An arrayref of other BOM::System::Host::Roles that this role inherits, so that a server role can be composed from other server roles.

Note that due to implementation concerns, this attribute must be rw instead of ro, and must be constrained simlpy as an ArrayRef rather than as an ArrayRef[BOM::System::Host::Role]. These two relaxed constraints allow us to initially construct the BOM::System::Host::Role with the I<inherits> attribute as an arrayref of strings, which are later replaced by BOM::System::Host::Role objects via C<BOM::System::Host::Role::Registry::get> lookups. I'm not proud of it, but it works.

=cut

has inherits => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has all_roles => (
    is         => 'ro',
    isa        => 'ArrayRef',
    init_arg   => undef,
    lazy_build => 1,
);

=head1 METHODS

=head2 $self->has_role($role)

Returns true if $self->name eq $role, or if $self "inherits" a role which has_role($role).

Useful for composition.

=cut

sub has_role {
    my $self = shift;
    my $role = shift;

    return first { $role eq $_ } @{$self->all_roles};
}

sub _build_all_roles {
    my $self = shift;

    my @roles = map { @{$_->all_roles} } @{$self->inherits};
    push @roles, $self->name;

    return \@roles;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Nick Marden C<< <nick at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011- RMG Technology (M) Sdn Bhd

=cut
