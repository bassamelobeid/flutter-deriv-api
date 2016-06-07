package BOM::Platform::Plack;

=pod

 Routines that have something to do with the running of the code under
 plack.

=cut

use strict;
use warnings;

use CGI;
use CGI::Util;
use CGI::Cookie;
use DateTime::Format::Mail;
use Plack::App::CGIBin::Streaming;
use Try::Tiny;

use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::Platform::Context qw(request localize);
use base qw( Exporter );

our @EXPORT_OK = qw(
    http_redirect
    PrintContentType
    PrintContentType_XSendfile
    PrintContentType_XML
    PrintContentType_excel
    PrintContentType_image
    PrintContentType_JSON
    AjaxSession
);

sub is_web_server {
    return Plack::App::CGIBin::Streaming->request;
}

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

    my @cookies = ();
    if ($params->{'cookies'}) {
        @cookies = @{$params->{'cookies'}};
    }
    if (not request()->from_ui) {
        die "PrintContentType called outside ui";
    }

    my $lang = request()->language;

    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type("text/html; charset=UTF-8");

    $http_handler->print_header(
        'Cache-control' => "no-cache, no-store, private, must-revalidate, max-age=0, max-stale=0, post-check=0, pre-check=0",
        'Pragma'        => "no-cache",
        'Expires'       => "0",
    );

    if ($lang) {
        $http_handler->print_header('Content-Language' => lc $lang);
    }

    if (scalar @cookies > 0) {
        _header_set_cookie(\@cookies);
    }

    $http_handler->print_header(%{$params->{'extra_headers'}}) if $params->{'extra_headers'};

    if ($params->{'status_code'}) {
        $http_handler->status($params->{'status_code'});
        exit 0;
    } else {
        $http_handler->status(200);
    }
    exit 0 if request()->http_method eq 'HEAD';

    return;
}

sub _header_set_cookie {
    my $cookies          = shift;
    my %existing_cookies = CGI::Cookie->fetch;
    my @cookies          = sort grep { $_ } @$cookies;

    COOKIE:
    foreach my $cookie (@cookies) {
        foreach my $key (keys %existing_cookies) {
            my $chk = $key . '=' . CGI::Util::escape($existing_cookies{$key}->value // ' ');
            next COOKIE if $cookie =~ /^$chk;/;
        }
        if (request()->param('_pjax')) {
            die "Setting cookie($cookie) while serving page through pjax";
        }
        request()->http_handler->print_header_add('Set-Cookie' => $cookie);
    }
    return;
}

sub PrintContentType_XSendfile {
    my $filename     = shift;
    my $content_type = shift;
    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type($content_type);
    my $basename = $filename;
    $basename =~ s!.*/!!;
    $http_handler->print_header('Content-Disposition' => 'inline; filename=' . $basename);
    $http_handler->print_header('Cache-control'       => "private, no-cache, must-revalidate");

    $http_handler->print_header('X-Accel-Redirect' => '/-/download' . $filename);
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
    $http_handler->print_header('Content-Disposition' => 'attachment; filename=' . $filename . ($size ? ';size=' . $size : ''));
    $http_handler->print_header('Cache-control' => "private, no-cache, must-revalidate");
    $http_handler->status(200);
    return;
}

sub PrintContentType_image {
    my ($img_format) = @_;

    local $\ = '';

    my $http_handler = request()->http_handler;
    $http_handler->print_content_type("image/$img_format");
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

sub AjaxSession {
    return (request()->param('ajax_only') ? 1 : 0);
}

sub panic_code_timeout {
    #$SIG{'ALRM'} = \&DEFAULT; alarm(0);
    my $runtime = time - $^T;
    my $timenow = Date::Utility->new->datetime;

    warn("Panic timeout after $runtime seconds");

    if (not request()->from_ui) {
        print 'The script timed out.';
    } else {
        my $is_ajax_session = AjaxSession();

        my $suggest_whattodo = '';
        if (not $is_ajax_session) {
            my $website = request()->website;
            $suggest_whattodo =
                  '<p class="normalfonterror">'
                . '<a href="javascript:document.location.reload();"><b>'
                . localize('Reload page')
                . '</b></a> '
                . ' <a href="http://'
                . $website->primary_url . '">'
                . $website->primary_url . '</a> '
                . localize('homepage') . '</p>';
        }

        print '<div id="page_timeout_notice" class="aligncenter">'
            . '<p class="normalfonterror">'
            . $timenow . ' '
            . localize(
            'The page has timed out. This may be due to a slow Internet connection, or to excess load on our servers.  Please try again in a few moments.'
            )
            . '</p>'
            . $suggest_whattodo
            . '</div>';
    }

    BOM::Platform::Context::request_completed();
    exit;
}

1;

