#!/usr/bin/env perl 
use strict;
use warnings;

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use WebService::Async::Onfido;

use Scalar::Util qw(blessed);
use Log::Any qw($log);
use Getopt::Long;
use List::UtilsBy qw(rev_nsort_by);
use Digest::HMAC;
use Digest::SHA1;
use JSON::MaybeUTF8 qw(:v1);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    't|token=s'     => \my $token,
    'l|log=s'       => \my $log_level,
    'c|count=s'     => \my $count,
    'a|applicant=s' => \my $applicant_id,
    'e|endpoint=s'  => \my $endpoint,
) or die;

$endpoint ||= 'https://www.binaryqa23.com/onfido/';
$count //= 10;
$log_level ||= 'info';
Log::Any::Adapter->import(
    qw(Stdout),
    log_level => $log_level
);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $onfido = WebService::Async::Onfido->new(
        token => $token
    )
);
$loop->add(
    my $ua = Net::Async::HTTP->new(
        decode_content => 1,
        fail_on_error => 1,
    )
);

# When submitting checks, Onfido expects an identity document,
# so we prioritise the IDs that have a better chance of a good
# match. This does not cover all the types, but anything without
# a photo is unlikely to work well anyway.
my %document_priority = (
    uk_biometric_residence_permit => 5,
    passport                      => 4,
    passport_card                 => 4,
    national_identity_card        => 3,
    driving_licence               => 2,
    voter_id                      => 1,
    tax_id                        => 1,
    unknown                       => 0,
);

my $bypass;
my $handler = async sub {
    my ($check) = @_;
    try {
        my $payload = {
            payload => {
                action => "check.completed",
                object => {
                    completed_at => $check->created_at,
                    href         => $check->href,
                    id           => $check->id,
                    status       => "complete"
                },
                resource_type => "check"
            }
        };
        $log->infof('Submitting payload %s', $payload);
        my $content = encode_json_utf8($payload);
        my $digest = Digest::HMAC->new(
            ($ENV{ONFIDO_WEBHOOK_TOKEN} // die 'need ONFIDO_WEBHOOK_TOKEN env var'),
            'Digest::SHA1'
        );
        $digest->add($content);
        return await $ua->POST(
            $endpoint,
            $content,
            content_type => 'application/json',
            headers => {
                'X-Signature' => $digest->hexdigest
            }
        )
    } catch {
        $log->errorf('Failed to submit notification - %s', $@);
        die $@;
    }
};

if($applicant_id) {
    $bypass = 1;
    $onfido->applicant_get(
        applicant_id => $applicant_id,
    )->then(sub {
        shift->checks
            ->map($handler)
            ->resolve
            ->as_list
    })->get
} else {
    $onfido->applicant_list
        ->flat_map('checks')
        ->take($count)
        ->map($handler)
        ->resolve
        ->await;
}

