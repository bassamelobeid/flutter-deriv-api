package BOM::MapFintech;

use strict;
use warnings;
use YAML::XS qw(LoadFile);
use Net::SFTP::Foreign;

=head1 NAME

BOM::MapFintech - a simple SFTP wrapper for uploading our daily reporting files to MAP Fintech

=head3 upload()

Argument 1 is the path to the files
Argument 2 is an arrayref of the filenames

If any part of the process fails, the error will be returned as a string.
Otherwise, undef will be returned.

=cut

my $sftp;

sub upload {
    my ($path, $fnames) = @_;

    $sftp ||= _by_pw();

    return $sftp->status if $sftp->error;

    foreach my $fn (@$fnames) {
        $sftp->put("$path/$fn", "upload/$fn");
        return $sftp->status if $sftp->error;
    }

    return undef;
}

# These two functions are to cover our bases
# We provided them with a public key, but were told it would take some time before that was setup
# In the interim, we need to use the pw they provided to us

sub _by_pw {
    my $config = LoadFile('/etc/rmg/third_party.yml');
    return Net::SFTP::Foreign->new(
        $config->{mapfintech}->{host},
        user     => $config->{mapfintech}->{user},
        password => $config->{mapfintech}->{pass});
}

sub _by_public_key {
    my $config = LoadFile('/etc/rmg/third_party.yml');
    return Net::SFTP::Foreign->new(
        $config->{mapfintech}->{host},
        user     => $config->{mapfintech}->{user},
        key_path => '/home/nobody/.ssh/mapfintech',
        more     => [qw(-o PreferredAuthentications=publickey)]);
}

1;
