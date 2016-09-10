use strict;
use warnings;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use Suite;

use Time::HiRes qw(tv_interval gettimeofday);
use List::Util qw(min max sum);
use POSIX qw(floor ceil);
# TODO Flag any warnings during initial development - note that this should be handled at
# prove level as per other repos, see https://github.com/regentmarkets/bom-rpc/pull/435 for example
use Test::FailWarnings;

use Mojo::UserAgent;

my @times;
for my $iteration (1..10) {
    # Suite->run is likely to set the system date. Rely on the HW clock to give us times, if possible.
    system(qw(sudo hwclock --systohc)) and die "Failed to sync HW clock to system - $!";
    my $t0 = [gettimeofday];
    my $elapsed = Suite->run('loadtest.conf');
    system(qw(sudo hwclock --hctosys)) and die "Failed to sync system clock to HW - $!";
    my $wallclock = tv_interval( $t0, [gettimeofday]);
    diag "Took $wallclock seconds wallclock time for loadtest including setup, $elapsed seconds cumulative step time";
    push @times, $elapsed;
}

my @sorted = (sort { $a <=> $b } @times);
# From https://help.datadoghq.com/hc/en-us/articles/206955236-Metric-types-in-Datadog
# histogram submits as multiple metrics:
# Name                | Web App type
# -----               | ------------
# metric.max          | GAUGE
# metric.avg          | GAUGE
# metric.median       | GAUGE
# metric.95percentile | GAUGE
# metric.count        | RATE
my %stats = (
    'min'          => min(@times),
    'avg'          => sum(@times) / @times,
    'median'       => @sorted[floor(@sorted/2)..ceil(@sorted/2)] / 2,
    '95percentile' => @sorted[0.95 * @sorted],
    'max'          => max(@times),
);
diag sprintf "min/avg/max - %.3fs/%.3fs/%.3fs", @stats{qw(min avg max)};

if(defined $ENV{TRAVIS_DATADOG_API_KEY}) {
    my $ua = Mojo::UserAgent->new;
    my $now = Time::HiRes::time;
    chomp(my $git_info = `git rev-parse --abbrev-ref HEAD`);
    my $metric_base = 'bom_websocket_api.v_3.loadtest.timing';
    my %args = (
        # probably want a source:travis tag, but http://docs.datadoghq.com/api/?lang=console#tags claims
        # that's not valid.
        # https://help.datadoghq.com/hc/en-us/articles/204312749-Getting-started-with-tags
        # "Tags must start with a letter, and after that may contain alphanumerics, underscores,
        # minuses, colons, periods and slashes. Other characters will get converted to underscores.
        # Tags can be up to 200 characters long and support unicode. Tags will be converted to lowercase."
        tags   => [
            'tag:' . $git_info,
            ($ENV{TRAVIS_PULL_REQUEST} ? 'pr:' . $ENV{TRAVIS_PULL_REQUEST} : ()),
            ($ENV{TRAVIS_BRANCH} ? 'branch:' . $ENV{TRAVIS_BRANCH} : ()),
        ],
        host   => $ENV{TRAVIS_DATADOG_API_HOST} // 'travis',
    );
    my $tx = $ua->post(
        'https://app.datadoghq.com/api/v1/series?api_key=' . $ENV{TRAVIS_DATADOG_API_KEY},
        json => {
            series => [
                (map +{
                    %args,
                    metric => $metric_base . '.' . $_,
                    points => [ [ $now, $stats{$_} ] ],
                    type   => 'gauge',
                }, sort keys %stats), {
                    # Include count separately, since it's a different type
                    %args,
                    metric => $metric_base . '.count',
                    points => [ [ $now, scalar @times ] ],
                    type   => 'rate',
                }
            ],
        }
    );
    unless($tx->success) {
        my $err = $tx->error;
        fail('unable to post datadog stats - ' . $err->{code} . ' ' . $err->{message});
    }
}

cmp_ok($stats{avg}, '>=', 12, 'average time was above the lower limit, i.e. tests are not suspiciously fast');
cmp_ok($stats{avg}, '<=', 21, 'average time was below our upper limit, i.e. we think overall test time has not increased to a dangerously high level');

done_testing();

