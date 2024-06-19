#!/etc/rmg/bin/perl

=head1 NAME

crypto_payment_processor_webhook_sender

=head1 SYNOPSIS

    perl crypto_payment_processor_webhook_sender.pl

=head1 DESCRIPTION

Manually sends the payment processor payload to our crypto webhook listener.

B<NOTE:> This helper script is meant to be used only on QA machines
since they are not exposed to 3rd-party as of now.

=cut

use strict;
use warnings;

use Data::Dumper;
use Digest::SHA qw(hmac_sha512_hex);
use Getopt::Long;
use HTTP::Tiny;
use URI;
use Syntax::Keyword::Try;

use BOM::Config;

GetOptions(
    "endpoint=s"   => \my $endpoint,
    "secret_key=s" => \my $secret_key,
    "payload=s"    => \my $payload,
);

$endpoint   //= '/api/v1/coinspaid';
$secret_key //= BOM::Config::third_party()->{crypto_webhook}{coinspaid}{secret_key};

# NOTE: Paste the "Request body" from CoinsPaid's Callback inside the single-quotes below:
$payload //= '';

die 'Please provide the callback "payload" in the script.'
    unless $payload;

my %options = (
    headers => {
        Accept                   => 'application/json',
        'Content-Type'           => 'application/json',
        'X-Processing-Signature' => hmac_sha512_hex($payload, $secret_key) . '',
    },
    content => $payload,
);

my $ua  = HTTP::Tiny->new(timeout => 20);
my $uri = URI->new(sprintf('http://%s:%s', 'localhost', '8236'));

$uri->path($endpoint);

my $response = $ua->request('POST', "$uri", \%options);

try {
    warn Dumper sprintf('Response code: %s', $response->{status});
} catch {
    warn Dumper $response->{content};
}
