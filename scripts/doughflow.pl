use strict;
use warnings;

use Log::Any qw($log);
use Getopt::Long 'GetOptions';

use Digest::MD5 qw/md5_hex/;
use Mojo::UserAgent;

use BOM::User::Client;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $usage = "Usage: $0 -e <URL> -s <secret_key> -c <client_loginid> -l <debug|info|error>\n";

require Log::Any::Adapter;
GetOptions(
    'a|action=s'         => \my $action,
    'e|endpoint=s'       => \my $endpoint_url,
    's|secret_key=s'     => \my $secret_key,
    'c|client_loginid=s' => \my $client_loginid,
    'l|log=s'            => \my $log_level,
    't|trace_id=i'       => \my $trace_id,
) or die $usage;

# Note: The 'withdrawal' endpoint will be removed soon,
# 'update_payout' is the one which does real withdrawal.
my $actions = {
	'deposit' => 'post',
	'deposit_validate' => 'get',
	'withdrawal' => 'post',
	'withdrawal_validate' => 'get',
	'withdrawal_reversal' => 'post',
	'update_payout' => 'post',
};

$log_level ||= 'info';
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

die "ERROR: action must be one of the actions in the actions list. $usage" unless $action and exists($actions->{$action});
die "ERROR: endpoint url must be specified. $usage"   unless $endpoint_url;
die "ERROR: secret phrase must be specified. $usage"  unless $secret_key;
die "ERROR: client loginid must be specified. $usage" unless $client_loginid;
if ($action =~ /^withdrawal_reversal$/ and not $trace_id) {
    die "ERROR: trace_id must be specified if action is withdrawal_reversal. $usage";
}

#die 'Invalid url' unless $endpoint_url =~ /^https:\/\/paymentapi.binary.com\/paymentapi$/;

my $client = BOM::User::Client->new({loginid => $client_loginid}) or die "Invalid login ID: $client_loginid";
my $params = {
    client_loginid    => $client_loginid,
    amount            => 1,
    currency_code     => $client->account->currency_code,
    payment_processor => 'AirTM',
    trace_id          => $trace_id ||int(rand(999999)),
};

$log->debugf('Trying $s with %s', $action, $params);

my $url = "$endpoint_url/transaction/payment/doughflow/$action";
if ($action eq 'update_payout') {
	$params->{status} = 'inprogress'
}

$log->debugf('Connecting to %s', $url);

my $key       = $secret_key;
my $timestamp = time - 1;

my $calc_hash = Digest::MD5::md5_hex($timestamp . $key);
$calc_hash = substr($calc_hash, length($calc_hash) - 10, 10);

my $ua = Mojo::UserAgent->new;
my $tx = ($actions->{$action} eq 'get')
	? $ua->get($url => {'X-BOM-DoughFlow-Authorization' => "$timestamp:$calc_hash"} => form => $params)
	: $ua->post($url => {'X-BOM-DoughFlow-Authorization' => "$timestamp:$calc_hash"} => form => $params);

my $result      = $tx->result;
my $result_code = $result->code;    # 201 means success

$log->debugf('Transaction result is %s', $result);

if ($result_code =~ /^2/) {
    $log->infof('%s successful. Status code: %s', $action, $result_code);
} else {
    $log->errorf('%s failed. Status code: %s', $action, $result_code);
}

1;