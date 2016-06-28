package WWW::OneAll;

use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::Util qw(b64_encode);

our $VERSION = '0.01';

use vars qw/$errstr/;
sub errstr { $errstr }

sub new {
    my $class = shift;
    my %args  = @_ % 2 ? %{$_[0]} : @_;

    for (qw/subdomain public_key private_key/) {
        $args{$_} || croak "Param $_ is required.";
    }

    $args{endpoint} ||= "https://" . $args{subdomain} . ".api.oneall.com";
    $args{timeout}  ||= 60; # for ua timeout

    return bless \%args, $class;
}

sub __ua {
    my $self = shift;

    return $self->{ua} if exists $self->{ua};

    my $ua = Mojo::UserAgent->new;
    $ua->max_redirects(3);
    $ua->inactivity_timeout($self->{timeout});
    $ua->proxy->detect; # env proxy
    $ua->cookie_jar(0);
    $ua->max_connections(100);
    $self->{ua} = $ua;

    return $ua;
}

sub connection {
    my ($self, $connection_token) = @_;

    return $self->request('GET', "/connection/$connection_token");
}

sub request {
    my ($self, $method, $url, %params) = @_;

    $errstr = ''; # reset

    my $ua = $self->__ua;
    my $header = {
        Authorization => 'Basic ' . b64_encode($self->{public_key} . ':' . $self->{private_key}, '')
    };
    $header->{'Content-Type'} = 'application/json' if %params;
    my @extra = %params ? (json => \%params) : ();
    my $tx = $ua->build_tx($method => $self->{endpoint} . $url . '.json' => $header => @extra);
    $tx->req->headers->accept('application/json');

    $tx = $ua->start($tx);
    if ($tx->res->headers->content_type and $tx->res->headers->content_type =~ 'application/json') {
        return $tx->res->json;
    }
    if (! $tx->success) {
        $errstr = "Failed to fetch $url: " . $tx->error->{message};
        return;
    }

    $errstr = "Unknown Response.";
    return;
}

1;