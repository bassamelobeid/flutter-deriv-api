package BOM::System::Plack::App;

use strict;
use warnings;

use Try::Tiny::Except ();    # preload: see BOM::Platform::Sysinit
use Plack::Builder;
use Plack::App::CGIBin::Streaming;
use Time::HiRes ();
use File::Copy  ();
use File::Path  ();
use BOM::Utility::Log4perl qw/get_logger/;

BEGIN {
    $ENV{ERROR_LOG} ||= 'error_log';
    open STDERR, '>>', $ENV{ERROR_LOG} or die "Cannot open $ENV{ERROR_LOG}: $!";
    select +(select(STDERR), $| = 1)[0];    ## no critic

    my $t = Time::HiRes::time;
    require CGI;
    CGI->compile(qw/:cgi :cgi-lib/);

    my $tmp_dir = '/tmp';
    -d $tmp_dir or die "$tmp_dir does not exist!";

    my $gif_dir      = '/home/website/www/temp';
    my $tmp_gnu_plot = $tmp_dir . '/gnuplot';

    my ($uid, $gid) = (getpwnam "nobody")[2, 3];
    foreach my $dir ($gif_dir, $tmp_gnu_plot) {
        unless (-d $dir) {
            File::Path::mkpath(
                $dir,
                {
                    uid   => $uid,
                    group => $gid
                });
            -d $dir or die "Error - $dir could not be created";
        }
    }
    $tmp_gnu_plot .= '/gnuplot';

    # Copy GNUPLOT to the tmp drive (normally a ram drive on live servers)
    my $gnu_plot = '/usr/bin/gnuplot';
    -f $gnu_plot
        or die "GnuPlot does not exist at its required location [" . $gnu_plot . "]";

    unless (-x $tmp_gnu_plot) {
        File::Copy::copy($gnu_plot, $tmp_gnu_plot)
            or die "Cannot copy GnuPlot from [$gnu_plot] to [$tmp_gnu_plot]";

        # Make sure it's executable
        chmod 0755, $tmp_gnu_plot
            or die "Can't change permissions for [$tmp_gnu_plot] to [0755]";
    }
}

sub app {    ## no critic
    my %options = @_;

    my $alog;
    if ($ENV{ACCESS_LOG}) {
        open $alog, '>>', $ENV{ACCESS_LOG}    ## no critic
            or die "Cannot open access_log: $!";
        select +(select($alog), $| = 1)[0];    ## no critic
    }

    $options{preload} //= ["*.cgi"];
    $options{root} //= "/home/git/regentmarkets/bom-app";

    my $app = BOM::System::Plack::Streaming->new(
        %options,
        request_class => 'BOM::System::Plack::Request',
    );
    my $app_sub = $app->to_app;

    get_logger()->info("precompiled " . (keys %{$app->{_compiled}}) . " scripts");

    return builder {
        enable 'AccessLog::Timed' => (
            format => '%h %l %u %t "%r" %>s %b %D',
            logger => sub { local $\; print $alog $_[0] },
        ) if $alog;
        $app_sub;
    };
}

package BOM::System::Plack::Streaming;    ## no critic

use strict;
use warnings;
use parent 'Plack::App::CGIBin::Streaming';

use BOM::Utility::Log4perl qw/get_logger/;
use Try::Tiny;

# The control flow is a bit difficult to understand here. Hence, ...
# Plack::App::CGIBin::Streaming takes a script and compiles it into
# a subroutine using CGI::Compile. That sub is then passed to mkapp().
# So, overwriting mkapp is a convenient way to adjust the environment
# the script runs in.
#
# In our case we:
#
# 1) configure Try::Tiny to pass through a special exception used by
#    CGI::Compile to signal exit of the script.
# 2) catch exceptions thrown by the script.

sub mkapp {
    my ($self, $real) = @_;

    my $sub = sub {
        try {
            local $Try::Tiny::Except::always_propagate = sub {
                ref eq 'ARRAY' and @$_ == 2 and $_->[0] eq "EXIT\n";
            };

            $real->();
        }
        catch {
            # log the error unless it is a reference. This avoids stuff
            # like ARRAY(0x17fb998) in the logs and also provides a way
            # for the sender of the exception to log the issue where it
            # occurred and then simply longjmp out of a deep call stack.
            # Best if you use an exception object for this purpose that
            # overloads '""', like Mojo::Exception. In that case the
            # exception could also be handled in an intermediate stack
            # frame as if it were a normal string.
            get_logger->error($_) unless ref;

            # in many cases the HTTP status seen by the client cannot
            # be changed anymore. But we still can set it for our own
            # accounting in case we write a log.
            $Plack::App::CGIBin::Streaming::R->status(500);
        };
    };

    return $self->SUPER::mkapp($sub);
}

package BOM::System::Plack::Request;    ## no critic

use strict;
use warnings;
use parent 'Plack::App::CGIBin::Streaming::Request';
my $cleanup_key = "register_cleanup : " . __FILE__ . " : " . __LINE__;

sub new {
    my $class = shift;
    $class = ref($class) || $class;

    my $self = $class->SUPER::new(@_);

# PBP requests ":encoding(utf8)" instead of ":utf8". Only for output handles that
# does not make any sense other that it worsens performance. For input handles it
# makes sense because it checks data. But STDOUT here is strictly for output.
#
# To prove that I measured the difference:
#
# perl -MBenchmark=:all,:hireswallclock -Mstrict -Mutf8 -e '
#     my $s="äöü" x 1000;
#     my $buf;
#     sub en {open my $f, ">", \$buf; binmode $f, ":encoding(utf8)"; print $f $s}
#     sub ut {open my $f, ">", \$buf; binmode $f, ":utf8";           print $f $s}
#     cmpthese timethese -3, {en=>\&en, ut=>\&ut}
# '
# Benchmark: running en, ut for at least 3 CPU seconds...
#         en: 3.25427 wallclock secs ( 3.25 usr +  0.01 sys =  3.26 CPU) @ 53620.86/s (n=174804)
#         ut: 3.14231 wallclock secs ( 3.14 usr +  0.00 sys =  3.14 CPU) @ 85151.27/s (n=267375)
#       Rate   en   ut
# en 53621/s   -- -37%
# ut 85151/s  59%   --
#
# To me the result is pretty clear -- ignore PBP.

    binmode STDOUT, ':utf8';    ## no critic

    $self->max_buffer     = 1000;
    $self->suppress_flush = 1;
    $self->content_type   = 'text/plain';
    $self->on_finalize    = sub {
        while (my $cb = pop @{$self->notes->{$cleanup_key} || []}) {
            $cb->();
        }
    };
    $self->on_status_output = sub {
        my $r = $_[0];

        $r->print_header('X-Accel-Buffering', 'no')
            if $r->status == 200 and $r->content_type =~ m!^text/html!i;
    };
    $self->filter_after = sub {
        my ($r, $list) = @_;

        unless ($r->status == 200 and $r->content_type =~ m!^text/html!i) {
            $r->filter_after = sub { };
            return;
        }

        for my $chunk (@$list) {
            if ($chunk =~ /<!-- FlushHead -->/) {
                $r->filter_after = sub { };
                $r->flush;
                return;
            }
        }
    };

    return $self;
}

sub register_cleanup {
    my ($self, $sub) = @_;

    push @{$self->notes->{$cleanup_key}}, $sub;
    return;
}

sub method      { return $_[0]->{env}->{REQUEST_METHOD} }
sub port        { return $_[0]->{env}->{SERVER_PORT} }
sub user        { return $_[0]->{env}->{REMOTE_USER} }
sub request_uri { return $_[0]->{env}->{REQUEST_URI} }
sub path_info   { return $_[0]->{env}->{PATH_INFO} }
sub path        { return $_[0]->{env}->{PATH_INFO} || '/' }
sub script_name { return $_[0]->{env}->{SCRIPT_NAME} }

BEGIN {
    *print_header_add = \&Plack::App::CGIBin::Streaming::Request::print_header;
    *print            = \&Plack::App::CGIBin::Streaming::Request::print_content;
}

sub print_content_type {
    my $self = shift;

    return $self->content_type($_[0]);
}

1;
