package Commission::Config::SymbolMap;

use strict;
use warnings;

use YAML::XS qw(LoadFile);
use Path::Tiny;

=head1 NAME

Commission::Config::SymbolMap - a simple config symbol mapping module for external trading platforms.

=head1 SYNOPSIS

use Commission::Config::SymbolMap;

my $config = Commission::Config::SymbolMap->new();
$config->target_symbol('dxtrade'. 'UK 100');

=head1 DESCRIPTION

Underlying symbols could be different across trading platforms. We should map these symbols with our internal definition
for reporting and clarification.

=cut

my $path          = path(__FILE__)->parent(4)->child('share', 'symbol_maps.yml');
my $symbol_config = LoadFile($path);

=head2 new

Creates a new object.

=cut

sub new {
    my $class = shift;

    my $self = {config => $symbol_config};

    return bless $self, $class;
}

=head2 target_symbol

Returns target_symbol configuration

=over 4

=item $provider = external provider identifier. E.g. derivx

=item $source = external provider symbol

=back

=cut

sub target_symbol {
    my ($self, $provider, $source) = @_;

    return undef unless $self->{config}->{$provider};
    return $self->{config}->{$provider}{$source};
}

1;
