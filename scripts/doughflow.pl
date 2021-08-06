use strict;
use warnings;

use Log::Any qw($log);
use Getopt::Long 'GetOptions';

use Digest::MD5 qw/md5_hex/;
use Mojo::UserAgent;

use BOM::User::Client;
use Data::Dump 'pp';

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# endpoint for QA box is 127.0.0.1:8110
# 'update_payout' does a withdrawal.
my $actions = {
    'deposit'               => 'post',
    'deposit_validate'      => 'get',
    'withdrawal_validate'   => 'get',
    'create_payout'         => 'post',
    'update_payout'         => 'post',
    'approve_payout'        => '',
    'reject_payout'         => '',
    'shared_payment_method' => 'post',
};

my $usage = "
Usage: $0 
    -a, --action               One of " . (join ', ', keys %$actions) . "
    -e, --endpoint             Doughflow api url 
    -s, --secret_key           Secret key
    -c, --client_loginid       Client loginid 
    -t, --trace_id             Trace ID. Optional, default is a random number.
    --amount                   Optional, default is 1.
    -pm, --payment_method      Optional, default is AirTM
    -pp, --payment_processor   Optional, default is AirTM
    -f, --fee                  Optional
    -p, --shared_loginid       For shared payment method
    -pt, --payment_type        Payment type e.g. CreditCard
    -id, --account_identifier  Account identifier e.g. masked credit card number
    -l, --log                  debug, info or error
";

require Log::Any::Adapter;
GetOptions(
    'a|action=s'              => \my $action,
    'e|endpoint=s'            => \my $endpoint_url,
    's|secret_key=s'          => \my $secret_key,
    'c|client_loginid=s'      => \my $client_loginid,
    'l|log=s'                 => \my $log_level,
    't|trace_id=i'            => \my $trace_id,
    'amount=f'                => \my $amount,
    'f|fee=f'                 => \my $fee,
    'pp|payment_processor=s'  => \my $payment_processor,
    'pm|payment_method=s'     => \my $payment_method,
    'p|shared_loginid=s'      => \my $shared_loginid,      # Only needed for `shared_payment_method`
    'pt|payment_type=s'       => \my $payment_type,
    'id|account_identifier=s' => \my $account_identifier
);
die $usage unless ($action && $endpoint_url && $secret_key && $client_loginid);

$log_level ||= 'info';
Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'text',
    log_level => $log_level
);

die 'ERROR: action must be one of ' . (join ', ', keys %$actions) . ". $usage" unless $action and exists($actions->{$action});
die "ERROR: endpoint url must be specified. $usage"                            unless $endpoint_url;
die "ERROR: secret phrase must be specified. $usage"                           unless $secret_key;
die "ERROR: client loginid must be specified. $usage"                          unless $client_loginid;

#die 'Invalid url' unless $endpoint_url =~ /^https:\/\/paymentapi.binary.com\/paymentapi$/;

my $client = BOM::User::Client->new({loginid => $client_loginid}) or die "Invalid login ID: $client_loginid";

$amount ||= 1;
$payment_processor //= 'AirTM';
$payment_method    //= 'AirTM';
$trace_id ||= do {
    my $rnd = int(rand(999999));
    $log->infof('Using random trace_id: %s', $rnd);
    $rnd;
};

my $params = {
    client_loginid     => $client_loginid,
    amount             => $amount,
    currency_code      => $client->account->currency_code,
    trace_id           => $trace_id,
    payment_type       => $payment_type,
    account_identifier => $account_identifier,
    defined $fee ? (fee => $fee) : (),
};

# DF doesn't know both the payment processor and the payment method for all operations
# let's try to keep these requests' params similar to the real ones
if ($action =~ /(deposit|deposit_validate|withdrawal_validate)/) {
    $params->{payment_processor} = $payment_processor;
}

if ($action eq 'deposit') {
    $params->{payment_method} = $payment_method;
} elsif ($action =~ /[a-z]+_payout/) {
    $params->{payment_method} = $payment_method;
}

my $endpoint = $action;
if ($action =~ /(update|reject|approve)_payout/) {
    $endpoint = 'update_payout';
    my %target_status = (
        update  => 'inprogress',
        reject  => 'rejected',
        approve => 'approved'
    );
    $params->{status} = $target_status{$1};
}

# Shared PM needs the hardcoded error code and an error description
# containing the shared's loginid, hence the -p option is required.
if ($action eq 'shared_payment_method') {
    die "ERROR: shared client loginid must be specified. " . ($usage =~ s/\n$//gr) . " -p <shared_loginid>\n" unless $shared_loginid;
    $endpoint             = 'record_failed_withdrawal';
    $params->{error_code} = 'NDB2006';
    $params->{error_desc} = sprintf('Shared AccountIdentifier PIN: %s', $shared_loginid);
}

$log->debugf('Trying %s with %s', $endpoint, pp($params));

my $url = "$endpoint_url/transaction/payment/doughflow/$endpoint";

$log->debugf('Connecting to %s', $url);

my $key       = $secret_key;
my $timestamp = time - 1;

my $calc_hash = Digest::MD5::md5_hex($timestamp . $key);
$calc_hash = substr($calc_hash, length($calc_hash) - 10, 10);

my $ua = Mojo::UserAgent->new;
my $tx =
    ($actions->{$action} eq 'get')
    ? $ua->get($url => {'X-BOM-DoughFlow-Authorization' => "$timestamp:$calc_hash"} => form => $params)
    : $ua->post($url => {'X-BOM-DoughFlow-Authorization' => "$timestamp:$calc_hash"} => form => $params);

my $result      = $tx->result;
my $result_code = $result->code;                # 200 or 201 means success
my $body        = $result->body || '<empty>';

$log->debugf('Transaction result is %s', pp($result));

if ($result_code =~ /^2/) {
    $log->infof('%s successful. Status code: %s, message: %s', $action, $result_code, $body);
} else {
    $log->errorf('%s failed. Status code: %s, message: %s', $action, $result_code, $body);
}

1;
