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

            # the \$ prototype turns the buffer into a reference
            # to a scalar. This explains the extra dereference here.
            $nrecv += length ${$_[1]} if ${*{$_[0]}}{' benchmark '};

            return $n;
        };
    }
}

use Getopt::Long;
use Pod::Usage;
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
my $sample;

unless (GetOptions('fork=i'     => \$nproc,
                   'requests=i' => \$nreq,
                   'prefix=s'   => \$prefix,
                   'users=i'    => \$nuid,
                   'method=s'   => \$meth,
                   'batch=i'    => \$batch,
                   'datafile=s' => \$datf,
                   'sample=s'   => \$sample,
                  )) {
    pod2usage(1);
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
        # @tm is an ordered list of numbers. It does not make much sense to
        # save all of them. To get a good representation of the distribution
        # of these numbers we safe 500 data points. The first data point then
        # is a time where 0.2% of all requests were faster than that time.
        # Similarly, 0.4% of all requests were faster than the 2nd data point.
        # The interesting part of this data is basically the last 5-10%, that
        # is the last 25-50 data points where the curve is expected to bend
        # upwards.

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
        printf("send bandwidth: %.3f bytes/req, receive bandwidth: %.3f bytes/req\n",
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
    $w->autoflush(1);
    local $ENV{'COMPANY_LIMITS_ENABLED'} = 1;
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
    # patch the landing company to prevent overwriting potentially
    # important data
    $x->{landing_company}=$prefix;

    # just in case there is no data for realized loss:
    $x->_add_sells(map {C->new} 1..1000);

    if ($sample) {
        my $fh;
        if ($sample eq '-') {
            $fh = \*STDOUT;
        } else {
            open $fh, '>', "$sample.$$"
                or warn "Cannot open $sample.$$: $!\n";
        }
        my @res = $x->$meth(map {C->new} 1..2);
        use Data::Dumper;
        print $fh +Data::Dumper->new([\@res], [qw/res/])->Useqq(1)->Sortkeys(1)->Dump;
        close $fh unless $fh = \*STDOUT;
    }

    ${*{$x->{redis}->{_socket}}}{' benchmark '} = 1;
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

__END__

=head1 NAME

benchmark-companylimits.pl - a tool to benchmark the company limits subsystem

=head1 SYNOPSIS

[B<nobw>=boolean] B<perl benchmark-compaqnylimits.pl>
[S<B<-fork> I<number-of-parallel-threads>>]
[S<B<-requests> I<total-number-requests>>]
[S<B<-prefix> I<string>>]
[S<B<-users> I<number-of-emulated-users>>]
[S<B<-method> I<method-to-benchmark>>]
[S<B<-batch> I<number-of-users-per-request>>]
[S<B<-datafile> I<filename-to-write-details>>]
[S<B<-sample> I<filename-to-write-sample-return-value>>]

=head1 DESCRIPTION

The B<benchmark-companylimits.pl> is used to measure different
aspects of the company limits subsystem.

=head1 OPTIONS

All options can be abbreviated.

=over 4

=item B<-fork> I<number-of-parallel-threads>

Specify number of concurrent execution threads. The program spawns as much sub-processes.
The default value is B<4>. The number of requests (see below) must be a multiple of this
value. If it's not, it will be adjusted downwards.

=item B<-requests> I<total-number-requests>

Specify the total number of requests to run. The default value is B<100000>. The work is
distributed between the workers. Each worker runs the same amount of requests. This
is the reason why this number has to be a multiple of the number of execution threads
(see above). If it is not, it is adjusted downwards.

=item B<-prefix> I<string>

The limits subsystem modifies values in Redis. Usually the landing company short name
is used as part of all redis keys. This option allows to change this part to avoid
tampering information in a production setup. The default value is B<benchmark>.

=item B<-users> I<number-of-emulated-users>

The overall number of keys in redis affected by the limits subsystem depends on the
number of active users. This option allows to set this number. The default value is
B<5000>.

=item B<-method> I<method-to-benchmark>

By default the benchmark tool measures the B<I<_add_buys>> method. This is the innermost
method which performs all redis operations for buying a contract. Other possible
values can be I<add_buys>, I<_add_sells> or I<add_sells>. I<add_buys> differs from
I<_add_buys> in that the former sends data also to datadog. The relationship for
sells is the same.

=item B<-batch> I<number-of-users-per-request>

This option allows to emulate the I<buy-contract-for-multiple-accounts> situation.
The default value is B<1>. The limits subsystem uses redis transactions. All changes
are sent in a single transaction. The number of users per request affects the size
of these transactions and, thus, the performance.

=item B<-datafile> I<filename-to-write-details>

This option allows to extract more details about the time distribution. Each request
is timed separately. The times are then sorted. Out of this sorted list, 500 evenly
distributed values are extracted. This means the fastest 0.2% of all requests were
faster than the first extracted value, the fastest 0.4% faster than the 2nd value and
so on. The last extracted value is the maximum. This allows for instance to plot
a distribution graph.

If this option is omitted, no file is written.

=item B<-sample> I<filename-to-write-sample-return-value>

This option allows to verify a sample of the return value of the I<method>. Each
execution thread first performs one operation gathering the result. This result
is then dumped to the specified file. If the filename given is I<->, the output
is written to STDOUT. Otherwise, the PID of the current process is added to the
filename and the output is written to that file.

If this option is omitted, this step is skipped.

=back

=head1 ENVIRONMENT

=over 4

=item B<nobw>

By default, this script hooks the Perl core's I<send> and I<recv> functions to
measure the number of bytes written to and received from Redis. Since this can
affect the performance, this environment variable allows to turn this measurement
off.

=back
