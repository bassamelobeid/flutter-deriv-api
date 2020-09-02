use strict;
use warnings;

use Log::Any qw($log);
use Getopt::Long 'GetOptions';

use Digest::MD5 qw/md5_hex/;
use Mojo::UserAgent;

use BOM::User::Client;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $usage = "Usage: $0 -a <action> -e <URL> -s <secret_key> -c <client_loginid> -l <debug|info|error>\n";

require Log::Any::Adapter;
GetOptions(
    'a|action=s'         => \my $action,
    'e|endpoint=s'       => \my $endpoint_url,
    's|secret_key=s'     => \my $secret_key,
    'c|client_loginid=s' => \my $client_loginid,
    'l|log=s'            => \my $log_level,
    't|trace_id=i'       => \my $trace_id,
) or die $usage;

# endpoint for QA box is 127.0.0.1:8110
# 'update_payout' does a withdrawal.
my $actions = {
	'deposit' => 'post',
	'deposit_validate' => 'get',
	'withdrawal_validate' => 'get',
	'update_payout' => 'post',
	'reject_payout' => '',
};

$log_level ||= 'info';
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

die 'ERROR: action must be one of '.(join ', ', keys %$actions).". $usage" unless $action and exists($actions->{$action});
die "ERROR: endpoint url must be specified. $usage"   unless $endpoint_url;
die "ERROR: secret phrase must be specified. $usage"  unless $secret_key;
die "ERROR: client loginid must be specified. $usage" unless $client_loginid;

#die 'Invalid url' unless $endpoint_url =~ /^https:\/\/paymentapi.binary.com\/paymentapi$/;

my $client = BOM::User::Client->new({loginid => $client_loginid}) or die "Invalid login ID: $client_loginid";
$trace_id ||= do {
    my $rnd = int(rand(999999));
    $log->infof('Using random trace_id: %s', $rnd);
    $rnd;
};

my $params = {
    client_loginid    => $client_loginid,
    amount            => 1,
    currency_code     => $client->account->currency_code,
    payment_processor => 'AirTM',
    trace_id          => $trace_id,
};

my $endpoint = $action;
if ($action eq 'reject_payout') {
    $endpoint = 'update_payout';
    $params->{status} = 'rejected'
}
if ($action eq 'update_payout') {
	$params->{status} = 'inprogress'
}

$log->debugf('Trying $s with %s', $endpoint, $params);

my $url = "$endpoint_url/transaction/payment/doughflow/$endpoint";

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
my $result_code = $result->code;    # 200 or 201 means success
my $body        = $result->body || '<empty>';

$log->debugf('Transaction result is %s', $result);

if ($result_code =~ /^2/) {
    $log->infof('%s successful. Status code: %s, message: %s', $action, $result_code, $body);
} else {
    $log->errorf('%s failed. Status code: %s, message: %s', $action, $result_code, $body);
}

1;
