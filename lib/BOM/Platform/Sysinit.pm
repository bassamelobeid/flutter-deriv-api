package BOM::Platform::Sysinit;

use warnings;
use strict;

use Time::HiRes ();
use Guard;
use File::Copy;
use Plack::App::CGIBin::Streaming;
use BOM::Platform::Context::Request;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Static::Config;    # called here as we generate hash for static files as it does not change on every request
use Try::Tiny::Except ();             # should be preloaded as early as possible
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
        # 30 minute timeout for backoffice scripts, 1 minute for client requests.
        my $timeout = (request()->backoffice or $0 =~ /backend/) ? 1800 : 60;

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
            BOM::Platform::Context::request_completed();
            exit;
        };
        alarm($timeout);

        # used for logging
        $ENV{BOM_ACCOUNT} = request()->loginid;    ## no critic

        $http_handler->register_cleanup(
            sub {
                delete @ENV{qw/BOM_ACCOUNT AUDIT_STAFF_NAME AUDIT_STAFF_IP/};    ## no critic
                BOM::Database::Rose::DB->db_cache->finish_request_cycle;
                alarm 0;
            });

        if (my $bo_cookie = request()->bo_cookie) {
            $ENV{AUDIT_STAFF_NAME} = $bo_cookie->clerk;                          ## no critic
        } else {
            $ENV{AUDIT_STAFF_NAME} = request()->loginid;                         ## no critic
        }
        $ENV{AUDIT_STAFF_IP} = request()->client_ip;                             ## no critic

        request()->http_handler($http_handler);
    } else {
        # We can ignore the alarm because we're not serving a web request here.
        # This is most likely happening in tests, long execution of which should be caught elsewhere.
        $SIG{'ALRM'} = 'IGNORE';    ## no critic
    }

    log_bo_access();

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->system and request()->from_ui and not request()->backoffice) {
        local $\ = '';
        my $http_handler = request()->http_handler;
        $http_handler->print_content_type("text/html; charset=UTF-8");
        $http_handler->print_header(
            'Cache-control' => "no-cache, no-store, private, must-revalidate, max-age=0, max-stale=0, post-check=0, pre-check=0",
            'Pragma'        => "no-cache",
            'Expires'       => "0",
        );
        $http_handler->status(200);
        print 'System is under maintenance.';
        BOM::Platform::Sysinit::code_exit();
    }

    return;
}

sub build_request {
    if (Plack::App::CGIBin::Streaming->request) {    # is web server ?
        if ($0 =~ /(bom-backoffice|contact)/) {
            $CGI::POST_MAX        = 8000 * 1024;     # max 8MB posts
            $CGI::DISABLE_UPLOADS = 0;
        } else {
            $CGI::DISABLE_UPLOADS = 1;               # no uploads
        }

        return request(
            BOM::Platform::Context::Request::from_cgi({
                    cgi         => CGI->new,
                    http_cookie => $ENV{'HTTP_COOKIE'},
                }));
    }
    return;
}

sub log_bo_access {
    if (BOM::Platform::Context::request()->backoffice) {
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
        my $staffname = request()->bo_cookie;
        $staffname = $staffname ? $staffname->clerk : 'unauthenticated';
        $staffname ||= 'unauthenticated';
        my $s = $0;
        $s =~ s/^\/home\/website\/www//;
        if ((-s "/var/log/fixedodds/staff-$staffname.log" or 0) > 750000) {
            File::Copy::move("/var/log/fixedodds/staff-$staffname.log", "/var/log/fixedodds/staff-$staffname.log.1");
        }
        Path::Tiny::path("/var/log/fixedodds/staff-$staffname.log")->append(Date::Utility->new->datetime . " $s $l\n");
    }
    return;
}

sub code_exit {
    BOM::Platform::Context::request_completed();
    exit 0;
}

1;

