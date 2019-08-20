package BOM::Datatracks;

use strict;
use warnings;

use Net::SFTP::Foreign;

=head1 NAME

BOM::Datatracks - a simple SFTP wrapper for uploading our daily reporting files to Datatracks

=head3 upload()

Argument 1 is the path to the files
Argument 2 is an arrayref of the filenames

If any part of the process fails, the error will be returned as a string.
Otherwise, undef will be returned.

=cut

my $sftp;

sub upload {
    my ($path, $fnames, $brand) = @_;

    $sftp ||= _by_public_key($brand);

    return $sftp->status if $sftp->error;

    foreach my $fn (@$fnames) {
        $sftp->put("$path/$fn", "BNRY/Input/$fn");
        return $sftp->status if $sftp->error;
    }

    return undef;
}

sub _by_public_key {
    my $brand = shift;
    return Net::SFTP::Foreign->new(
        'secure.datatracks.eu',
        user     => ucfirst($brand->name),
        key_path => '/home/nobody/.ssh/mfirmfsa',
        more     => [qw(-o PreferredAuthentications=publickey)]);
}

1;
