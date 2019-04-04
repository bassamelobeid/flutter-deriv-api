package BOM::Backoffice::PlackHelpers;

=pod

 Routines that have something to do with the running of the code under
 plack.

=cut

use strict;
use warnings;

use CGI;
use CGI::Util;
use CGI::Cookie;
use Try::Tiny;

use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use base qw( Exporter );

our @EXPORT_OK = qw(
    http_redirect
    PrintContentType
    PrintContentType_XSendfile
    PrintContentType_XML
    PrintContentType_excel
    PrintContentType_image
    PrintContentType_JSON
);

sub http_redirect {
    my ($new_url) = @_;

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type('text/html; charset=UTF-8');
    try {
        $http_handler->print_header(
            'Cache-Control' => 'private, no-cache, must-revalidate',
            'Location'      => $new_url,
        );
    }
    catch {
        /too late to set a HTTP header/ and warn($_);
        die $_;
    };
    $http_handler->status(302);    #Moved
    return;
}

sub PrintContentType {
    my $params = shift;

    if (not request()->from_ui) {
        die "PrintContentType called outside ui";
    }

    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type("text/html; charset=UTF-8");
    $http_handler->print_header(
        'Cache-control' => "no-cache, no-store, private, must-revalidate, max-age=0, max-stale=0, post-check=0, pre-check=0",
        'Pragma'        => "no-cache",
        'Expires'       => "0",
    );

    my $lang = request()->language;
    $http_handler->print_header('Content-Language' => CGI::Util::escape(lc $lang));

    if (exists $params->{'cookies'} && ref $params->{'cookies'} eq 'ARRAY' && scalar @{$params->{'cookies'}} > 0) {
        _header_set_cookie($params->{'cookies'});
    }

    $http_handler->status(200);
    exit 0 if request()->http_method eq 'HEAD';

    return;
}

sub _header_set_cookie {
    my $cookies          = shift;
    my %existing_cookies = CGI::Cookie->fetch;
    my @cookies          = sort grep { $_ } @$cookies;

    # Cookies passed here are made via CGI::Cookie, which are already escaped;
    # still, verify existing cookie values which we explicitly escape:
    COOKIE:
    foreach my $cookie (@cookies) {
        die 'given bad cookie to bake' unless ref $cookie eq 'CGI::Cookie';
        foreach my $key (keys %existing_cookies) {
            my $chk = CGI::Util::escape($key) . '=' . CGI::Util::escape($existing_cookies{$key}->value // ' ');
            next COOKIE if $cookie =~ /^$chk;/;
        }
        request()->http_handler->print_header('Set-Cookie' => $cookie);
    }
    return;
}

sub PrintContentType_XSendfile {
    my $filename      = shift;
    my $content_type  = shift;
    my $download_name = shift;
    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type($content_type);
    my $basename = $download_name || $filename;
    $basename =~ s!.*/!!;
    $http_handler->print_header('Content-Disposition' => 'inline; filename=' . CGI::Util::escape($basename));
    $http_handler->print_header('Cache-control'       => "private, no-cache, must-revalidate");

    $http_handler->print_header('X-Accel-Redirect' => '/-/download' . CGI::Util::escape($filename));
    $http_handler->status(200);
    return;
}

sub PrintContentType_XML {
    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type("text/xml; charset=UTF-8");
    $http_handler->print_header('Cache-control' => "private, no-cache, must-revalidate");
    $http_handler->status(200);
    return;
}

sub PrintContentType_excel {
    my ($filename, $size) = @_;
    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type("application/vnd.ms-excel");
    $http_handler->print_header(
        'Content-Disposition' => 'attachment; filename=' . CGI::Util::escape($filename) . ($size ? ';size=' . CGI::Util::escape($size) : ''));
    $http_handler->print_header('Cache-control' => "private, no-cache, must-revalidate");
    $http_handler->status(200);
    return;
}

sub PrintContentType_JSON {
    # NOTE: there are places in the code that rely on the content-type set
    #       by this function to be exactly 'application/json'.
    my $mime_type = 'application/json';
    binmode STDOUT, ":encoding(UTF-8)";

    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type($mime_type);
    try {
        $http_handler->print_header('Cache-control' => "private, no-cache, must-revalidate");
    }
    catch {
        /too late to set a HTTP header/ and warn($_);
        die $_;
    };
    $http_handler->status(200);
    return;
}

1;

