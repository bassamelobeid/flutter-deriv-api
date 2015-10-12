package BOM::Market::Role::ParsedOfferings;

use strict;
use warnings;
use 5.010;

use Moose::Role;
use Scalar::Util qw( reftype );
use YAML::CacheLoader;

sub BUILDARGS {
    my ($class, $args) = @_;

    if (ref($args) and $args->{contracts}) {
        # Divert so that we can work our magic below.
        $args->{_contracts} = $args->{contracts};
        delete $args->{contracts};
    }

    return $args;
}

# Parse the human-friendly YAML into computer-friendly perl structures.
has parsed_contracts => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_parsed_contracts',
);

has _contracts => (
    is => 'ro',
);

sub _build_parsed_contracts {
    my $self = shift;

    my $aliases = YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom/config/files/offerings/aliases.yml');

    my $offerings = _resolve_aliases($self->_contracts, $aliases);

    return $offerings;
}

sub _resolve_aliases {
    my ($entry, $aliases) = @_;

    my $whatsit = reftype($entry) // '';

    if ($entry) {
        if (not $whatsit and exists $aliases->{$entry}) {
            # Just an alias string for the whole deal
            $entry = $aliases->{$entry};
        } elsif ($whatsit eq 'HASH') {
            foreach my $key (keys %$entry) {
                $entry->{$key} = _resolve_aliases($entry->{$key}, $aliases);
            }
        }
    }

    return $entry;
}

1;
