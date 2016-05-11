package BOM::Platform::MyAffiliates::TrackingHandler;
use Moose;
use CGI qw( cookie );
use JSON qw( from_json );
use URL::Encode qw(url_decode);
use Try::Tiny;

use BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure;
use BOM::Platform::Client;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use Try::Tiny;

sub BUILD {
    my $self = shift;
    $self->_process_available_tracking_data;
    return;
}

has 'myaffiliates_token' => (
    is         => 'ro',
    isa        => 'Maybe[Str]',
    lazy_build => 1,
);

has 'tracking_cookie' => (
    is => 'rw',
);

sub _process_available_tracking_data {
    my $self = shift;

    if ($self->myaffiliates_token and request()->loginid) {
        $self->_delete_tracking_cookie;
        return;
    }

    return;
}

sub _delete_tracking_cookie {
    my $self = shift;

    $self->tracking_cookie(
        cookie(
            -name    => $self->_cookie_name,
            -value   => '',
            -domain  => request()->cookie_domain,
            -expires => '-1s',
            -path    => '/',
        ));

    return 1;
}

sub _build_myaffiliates_token {
    my $self = shift;
    my $tracking_data = $self->_tracking_data_from_cookie || return;
    return $tracking_data->{t};
}

sub _tracking_data_from_cookie {
    my $self          = shift;
    my $tracking_data = {};

    if (my $cookie_value = request()->cookie($self->_cookie_name)) {
        $cookie_value = url_decode($cookie_value);

        if ($cookie_value) {
            try {
                $tracking_data = from_json($cookie_value);
            }
            catch {
                $self->_delete_tracking_cookie;
                warn("Failed to parse tracking cookie from JSON [$cookie_value, raw: " . request()->cookie($self->_cookie_name) . "]: $_");
            };
        }
    }
    return $tracking_data;
}

has '_cookie_name' => (
    is      => 'ro',
    default => sub { BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->affiliate_tracking; },
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
