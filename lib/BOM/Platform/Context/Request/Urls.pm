package BOM::Platform::Context::Request::Urls;

use Mojo::URL;
use Moose::Role;

sub url_for {
    my ($self, @args) = @_;

    my $url = Mojo::URL->new($args[0] || '');
    my $query = $args[1] || {};

    $url->query($query);
    $url->path('/d/backoffice/' . $url->path);
    $url->host($self->domain_for());
    $url->scheme('https');

    return $url;
}

sub domain_for {
    my $self = shift;

    my @host_name = split(/\./, Sys::Hostname::hostname);
    my $server_name = $host_name[0];

    if ($server_name =~ /^(qa\d+)$/) {
        return "www.binary$1.com";
    }

    if ($server_name =~ /^backoffice.*$/) {
        return "backoffice.binary.com";
    }

    return $server_name . '.binary.com';
}

1;

=head1 COPYRIGHT

(c) 2013-, RMG Tech (Malaysia) Sdn Bhd

=cut
