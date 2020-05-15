
=head1 NAME

doughflow_deposit.pl - mimic the doughflow paymentapi deposit call

=head1 SYNOPSIS

    perl doughflow_deposit.pl -e <url> -s <secret_key> -c <loginid> -l debug

=head1 DESCRIPTION

This script does the following:

=over 4

=item * make a deposit request to paymentapi directly (locally), no doughflow involved, script can be used to test paymentapi functionality.

=back

It will report the status code - 201 means success and anyother code means failure.

It will credit client account. Transaction remark will have the payment processor and trace id

=cut

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
    'e|endpoint=s'       => \my $endpoint_url,
    's|secret_key=s'     => \my $secret_key,
    'c|client_loginid=s' => \my $client_loginid,
    'l|log=s'            => \my $log_level
) or die $usage;

$log_level ||= 'info';
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

die "ERROR: endpoint url must be specified. $usage"   unless $endpoint_url;
die "ERROR: secret phrase must be specified. $usage"  unless $secret_key;
die "ERROR: client loginid must be specified. $usage" unless $client_loginid;

my $client = BOM::User::Client->new({loginid => $client_loginid}) or die "Invalid login ID: $client_loginid";
my $params = {
    client_loginid    => $client_loginid,
    amount            => 1,
    currency_code     => $client->account->currency_code,
    payment_processor => 'AirTM',
    trace_id          => int(rand(999999)),
};

$log->debugf('Trying deposit with %s', $params);

my $url = "$endpoint_url/transaction/payment/doughflow/deposit";
$log->debugf('Connecting to %s', $url);

my $key       = $secret_key;
my $timestamp = time - 1;

my $calc_hash = Digest::MD5::md5_hex($timestamp . $key);
$calc_hash = substr($calc_hash, length($calc_hash) - 10, 10);

my $ua = Mojo::UserAgent->new;
my $tx = $ua->post($url => {'X-BOM-DoughFlow-Authorization' => "$timestamp:$calc_hash"} => form => $params);

my $result      = $tx->result;
my $result_code = $result->code;    # 201 means success

$log->debugf('Transaction result is %s', $result);

if ($result_code == 201) {
    $log->infof('Deposit successful. Status code: %s', $result_code);
} else {
    $log->errorf('Deposit failed. Status code: %s', $result_code);
}

1;
