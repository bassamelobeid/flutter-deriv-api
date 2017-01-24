package BOM::Backoffice::Sysinit;

use warnings;
use strict;

use Time::HiRes ();
use Guard;
use File::Copy;
use Path::Tiny;
use Plack::App::CGIBin::Streaming;
use BOM::Backoffice::Config;
use BOM::Backoffice::Cookie;
use BOM::Backoffice::Request::Base;
use BOM::Backoffice::Request qw(request localize);
use Try::Tiny::Except ();    # should be preloaded as early as possible
                             # this statement here is merely a comment.

sub init {
    $ENV{REQUEST_STARTTIME} = Time::HiRes::time;    ## no critic
    $^T = time;                                     ## no critic

    # Turn off any outstanding alarm, perhaps from a previous request in this mod_perl process,
    # while we figure out how we might want to alarm on this particular request.
    alarm(0);
    build_request();

    if (request()->from_ui) {
        {
            no strict;    ## no critic
            undef ${"main::input"}
        }
        my $http_handler = Plack::App::CGIBin::Streaming->request;

        my $timeout = 1800;

        $SIG{ALRM} = sub {    ## no critic
            my $runtime = time - $^T;
            my $timenow = Date::Utility->new->datetime;

            warn("Panic timeout after $runtime seconds");

            print '<div id="page_timeout_notice" class="aligncenter">'
                . '<p class="normalfonterror">'
                . $timenow . ' '
                . localize(
                'The page has timed out. This may be due to a slow Internet connection, or to excess load on our servers.  Please try again in a few moments.'
                )
                . '</p>'
                . '<p class="normalfonterror">'
                . '<a href="javascript:document.location.reload();"><b>'
                . localize('Reload page')
                . '</b></a> '
                . ' <a href="http://'
                . localize('homepage') . '</p>'
                . '</div>';
            BOM::Backoffice::Request::request_completed();
            exit;
        };
        alarm($timeout);

        $http_handler->register_cleanup(
            sub {
                delete @ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/};    ## no critic
                BOM::Database::Rose::DB->db_cache->finish_request_cycle;
                alarm 0;
            });

        $ENV{AUDIT_STAFF_NAME} = BOM::Backoffice::Cookie::get_staff();    ## no critic
        $ENV{AUDIT_STAFF_IP}   = request()->client_ip;                    ## no critic

        request()->http_handler($http_handler);
    } else {
        # We can ignore the alarm because we're not serving a web request here.
        # This is most likely happening in tests, long execution of which should be caught elsewhere.
        $SIG{'ALRM'} = 'IGNORE';    ## no critic
    }

    log_bo_access();

    return;
}

sub build_request {
    if (Plack::App::CGIBin::Streaming->request) {    # is web server ?
        $CGI::POST_MAX        = 8000 * 1024;         # max 8MB posts
        $CGI::DISABLE_UPLOADS = 0;
        return request(
            BOM::Backoffice::Request::Base::from_cgi({
                    cgi         => CGI->new,
                    http_cookie => $ENV{'HTTP_COOKIE'},
                }));
    }
    return;
}

sub log_bo_access {

    $ENV{'REMOTE_ADDR'} = request()->client_ip;    ## no critic

    # log it
    my $l;
    foreach my $k (keys %{request()->params}) {
        if ($k =~ /pass/) {
            next;
        }
        my $v = request()->param($k);
        $v =~ s/[\r\n\f\t]/ /g;
        $v =~ s/[^\w\s\,\.\-\+\"\'\=\+\-\*\%\$\#\@\!\~\?\/\>\<]/ /gm;

        if (length $v > 50) {
            $l .= "$k=" . substr($v, 0, 50) . "... ";
        } else {
            $l .= "$k=$v ";
        }
    }
    $l //= '(no parameters)';
    my $staffname = BOM::Backoffice::Cookie::get_staff();
    $staffname ||= 'unauthenticated';
    my $s = $0;
    $s =~ s/^\/home\/website\/www//;
    my $log = BOM::Backoffice::Config::config->{log}->{staff};
    $log =~ s/%STAFFNAME%/$staffname/g;
    if ((-s $log or 0) > 750000) {
        File::Copy::move($log, "$log.1");
    }
    Path::Tiny::path($log)->append_utf8(Date::Utility->new->datetime . " $s $l\n");

    return;
}

1;

