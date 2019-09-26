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
my $datf;

unless (GetOptions('fork=i'     => \$nproc,
                   'requests=i' => \$nreq,
                   'prefix=s'   => \$prefix,
                   'users=i'    => \$nuid,
                   'method=s'   => \$meth,
                   'batch=i'    => \$batch,
                   'datafile=s' => \$datf,
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
    my @tm;
    my ($snd, $rcv) = (0, 0);
    while (defined (my $l = readline $r)) {
        my ($prc, $tm, $_snd, $_rcv);
        if (($prc, $tm) = $l =~ /^tm: (\S+) (\S+)$/) {
            push @tm, $tm;
        } elsif (($prc, $_snd, $_rcv) = $l =~ /^bw: (\S+) (\S+) (\S+)$/) {
            $snd+=$_snd;
            $rcv+=$_rcv;
        } else {
            warn "got garbage from pipe: $l";
        }
    }

    @tm = sort {$a<=>$b} @tm;

    my $avg = 0;
    map {$avg+=$_} @tm;
    $avg/=@tm;

    printf "number of requests: %d, parallelism: %d\n", 0+@tm, $nproc;
    printf "min: %.3f ms, avg: %.3f ms, max: %.3f ms\n", $tm[0], $avg, $tm[-1];
    printf "median: <%.3f ms, 95%%: <%.3f ms, 99%%: <%.3f ms, 99.9%%: <%.3f ms\n",
        $tm[int(0.5+@tm*.5)],
        $tm[int(0.5+@tm*.95)],
        $tm[int(0.5+@tm*.99)],
        $tm[int(0.5+@tm*.999)],
        ;

    if ($datf and open my $fh, '>', $datf) {
        my $step = @tm/500;
        for (my $i=1; $i<500; $i++) {
            printf $fh "%d %.3f\n", int($i*$step), $tm[int($i*$step)];
        }
        printf $fh "%d %.3f\n", $#tm, $tm[-1];
    } elsif ($datf) {
        warn "datafile not written: $!\n";
    }

    unless ($ENV{nobw}) {
        printf("total bytes sent to redis: %d, number of bytes received from redis: %d\n",
               $snd, $rcv);
        printf("send bandwidth: %.3f bytes per request, receive bandwidth: %.3f bytes per request\n",
               $snd/@tm, $rcv/@tm);
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
    select [select($w), $|=1]->[0];
    my $contract = {bet_type => "higher_lower_bet",
                    underlying_symbol => "R_100",
                    short_code => "bla_S0P_0",
                    tick_count => 10,
                    payout_price => 100,
                    buy_price => 50,
                    sell_price => 45,
                    bet_class => "not a lookback option"};
    my $x=BOM::Transaction::CompanyLimits->new(landing_company => LandingCompany::Registry::get('virtual'),
                                               currency => "EUR",
                                               contract_data => $contract);
    ${*{$x->{redis}->{_socket}}}{' benchmark '} = 1;
    $x->{landing_company}=$prefix;
    # my @res = $x->$meth(map {C->new} 1..2);
    # use Data::Dumper; print +Data::Dumper->new([\@res], ['res'])->Useqq(1)->Sortkeys(1)->Dump;

    # just in case there is no data for realized loss:
    $x->add_sells(map {C->new} 1..1000);
    for (1..$nreq) {
        my $start = [Time::HiRes::gettimeofday];
        $x->$meth(map {C->new} 1..$batch);
        my $tm = Time::HiRes::tv_interval($start) * 1000; # in millisec
        print $w "tm: $$ $tm\n";
    }

    print $w "bw: $$ $nsend $nrecv\n";
    close $w;
    return 0;
}
