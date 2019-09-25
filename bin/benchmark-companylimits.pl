#!/etc/rmg/bin/perl

use strict;
use warnings;

my ($nsend, $nrecv) = (0, 0);

BEGIN {
    unless ($ENV{nobw}) {
        # We need to use prototyped subs here because the
        # CORE functions are also prototyped.
        *CORE::GLOBAL::send = sub (*$$;$) {
            my $n = &CORE::send;

            $nsend += $n if ${*{$_[0]}}{' benchmark '};

            return $n;
        };
        *CORE::GLOBAL::recv = sub (*\$$$) {
            my $n = &CORE::recv;

            $nrecv += length $_[1] if ${*{$_[0]}}{' benchmark '};

            return $n;
        };
    }
}

use Getopt::Long;
use BOM::Transaction::CompanyLimits;
use LandingCompany::Registry;
use Time::HiRes ();

my $nproc  = 4;
my $nreq   = 100000;
my $prefix = 'benchmark';
my $nuid   = 5000;
my $meth   = '_add_buys';
my $batch  = 1;

unless (GetOptions('fork=i'     => \$nproc,
                   'requests=i' => \$nreq,
                   'prefix=s'   => \$prefix,
                   'users=i'    => \$nuid,
                   'method=s'   => \$meth,
                   'batch=i'    => \$batch,
                  )) {
    ...;
}

{
    my $x = int ($nreq / $nproc);
    unless ($x * $nproc == $nreq) {
        warn "adjusting number of requests to ".($x * $nproc)."\n";
    }
    $nreq = $x;                 # this is now the number of reqs per thread
}

# We are using a pipe for the children to report back their values.
# A pipe guarantees that at least PIPE_BUF bytes are written atomically.
# POSIX requires PIPE_BUF to be at least 512. So, if all messages sent
# to the pipe are less than 512 bytes long, no further locking is
# required. (see pipe(7))
pipe my ($r, $w);
my @pids;
for (1..$nproc) {
    my $pid;
    select undef, undef, undef, 0.1 until defined($pid=fork);
    exit chld() unless $pid;
    push @pids, $pid;
}

close $w;
parent();

for (@pids) {
    waitpid $_, 0;
    if ($?) {
        my $sig = $? & 0xff;
        my $rc  = ($? & 0xff00)>>8;
        warn "$_ => sig=$sig, rc=$rc\n";
    }
}

sub parent {
    my @vals;
    my ($totsum, $totsq, $totn, $totmin, $totmax, $totsnd, $totrcv)
        = (0, 0, 0, '+inf', '-inf', 0, 0);
    for (1..$nproc) {
        warn ("Unexpected EOF on pipe: $!\n"), last
            unless defined (my $l = readline $r);
        my ($sum, $sumsq, $n, $min, $max, $nsnd, $nrcv) = split / /, $l;
        $totsum += $sum;
        $totsq += $sumsq;
        $totn += $n;
        $totsnd += $nsnd;
        $totrcv += $nrcv;
        $totmin = $min if $min < $totmin;
        $totmax = $max if $max > $totmax;
    }
    printf("total number of requests: %d, parallel: %d, avg time per req: %.3f msec, stddev: %.3f, ".
           "min: %.3f, max: %.3f\n",
           $totn, $nproc, $totsum/$totn, sqrt($totsq/$totn - ($totsum/$totn)**2), $totmin, $totmax);
    unless ($ENV{nobw}) {
        printf("total bytes sent to redis: %d, number of bytes received from redis: %d\n",
               $totsnd, $totrcv);
        printf("send bandwidth: %.3f bytes per request, receive bandwidth: %.3f bytes per request\n",
               $totsnd/$totn, $totrcv/$totn);
    }
}

sub C::binary_user_id {
    my $self = shift;
    return $$self;
}

sub C::new {
    return bless \(my $dummy = 1+int rand $nuid), 'C';
}

sub chld {
    close $r;
    srand;
    my $x=BOM::Transaction::CompanyLimits->new(landing_company => LandingCompany::Registry::get('virtual'),
                                               currency => "EUR",
                                               contract_data => {bet_type => "higher_lower_bet",
                                                                 underlying_symbol => "R_100",
                                                                 short_code => "bla_S0P_0",
                                                                 tick_count => 10,
                                                                 payout_price => 100,
                                                                 buy_price => 50,
                                                                 bet_class => "fsd"});
    ${*{$x->{redis}->{_socket}}}{' benchmark '} = 1;
    $x->{landing_company}=$prefix;
    # my @res = $x->$meth(map {C->new} 1..2);
    # use Data::Dumper; print +Data::Dumper->new([\@res], ['res'])->Useqq(1)->Sortkeys(1)->Dump;

    my ($sum, $sumsq, $min, $max) = (0, 0, '+inf', '-inf');
    for (1..$nreq) {
        my $start = [Time::HiRes::gettimeofday];
        $x->$meth(map {C->new} 1..$batch);
        my $tm = Time::HiRes::tv_interval($start) * 1000; # in millisec
        $sum += $tm;
        $sumsq += $tm ** 2;
        $min = $tm if $tm < $min;
        $max = $tm if $tm > $max;
    }

    print $w "$sum $sumsq $nreq $min $max $first $nsend $nrecv\n";
    close $w;
    return 0;
}
