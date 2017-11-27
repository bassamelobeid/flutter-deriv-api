package BOM::Cacher;

use strict;
use warnings;

use Cache::LRU;

use Exporter;
our @EXPORT_OK = qw(get_or_calculate);

my $cache = Cache::LRU->new(
    size => 1000,
);

my $prefix = '';

=head2 get_or_calculate

    Arguments: arrayref of key elemtns and coderef of function to cache.
    Function should return scalar.

    Returns: scalar, cached or calculated

=cut

sub get_or_calculate {
    my $k = shift;
    $k = join '_', $prefix, @$k;
    my $r;
    return $r if $r = $cache->get($k);
    $cache->set($k => shift->());
    return $cache->get($k);
}

=head2 set_key_prefix

    Arguments: string to prepend to all cache keys
    Returns: nothing

=cut

sub set_key_prefix {
    $prefix = shift // '';
    return;
}
1;
