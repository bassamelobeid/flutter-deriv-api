#!/etc/rmg/bin/perl
#
# Script get credit balance from Experian and send an email to compliance, if it is lower, than THRESHOLD.
# use option -d to have the script print the limits to the console.
#
use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;

use BOM::Backoffice::ExperianBalance;
use BOM::Config;
use BOM::Platform::Email qw(send_email);
use Mojo::UserAgent;
use Mojo::UserAgent::CookieJar;
use DataDog::DogStatsd::Helper qw(stats_inc);
use constant THRESHOLD => 25000;

my $brand = Brands->new(name => 'binary');

my ($used, $limit);
my $ua       = Mojo::UserAgent->new->cookie_jar(Mojo::UserAgent::CookieJar->new);
my $base_dir = '/etc/rmg/ssl/';
$ua->key($base_dir . 'key/experian.key');
$ua->cert($base_dir . 'crt/experian.crt');

try {
    ($used, $limit) = BOM::Backoffice::ExperianBalance::get_balance(
        $ua,
        BOM::Config::third_party()->{proveid}->{username},
        BOM::Config::third_party()->{proveid}->{password});
} catch ($e) {

    warn "An error occurred: $e";
}

unless ($used && $limit) {
    DataDog::DogStatsd::Helper::stats_inc('service.experian.failures', {tags => ["balance_check"]});
    die "Not able to get balance from experian.";
}

my $remain = $limit - $used;
if ($ARGV[0] and $ARGV[0] eq '-d') { print("Used: $used,  Limit: $limit\n"); exit; }
if ($remain < THRESHOLD) {
    my $threshold_msg = THRESHOLD;
    my $message       = <<"EOF";
Experian credits warning:
Limit: $limit
Used: $used

Remain: $remain
Threshold: $threshold_msg

EOF
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('compliance'),
        subject => 'Experian balance going low',
        message => [$message],
    });
}

