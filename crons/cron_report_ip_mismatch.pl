#!/etc/rmg/bin/perl

=head1 NAME

cron_report_ip_mismatch.pl

=head1 DESCRIPTION

This is a CRON script to report any mismatch of ip address country and client's residence

=cut

package main;
use strict;
use warnings;

use BOM::Backoffice::Request;
use BOM::Platform::Email qw(send_email);
use JSON::MaybeXS qw{decode_json};
use Date::Utility;
use LandingCompany::Registry;
use BOM::Config;
use BOM::Config::RedisReplicated;
use BOM::User::Client;
use BOM::User;
use Cache::RedisDB;

use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

my $redis = BOM::Config::RedisReplicated::redis_write;
use constant REDIS_MASTERKEY     => 'IP_COUNTRY_MISMATCH';
use constant REDIS_TRACK_CHECKED => 'CHECKED_ID';
my %ip_mismatch_data = @{$redis->hgetall(REDIS_MASTERKEY)};
my %client_retry_que;
my %landing_company_data;
my @mt5_retry_que;

for my $loginid (keys %ip_mismatch_data) {
    my $raw_data     = $ip_mismatch_data{$loginid};
    my $decoded_data = decode_json($raw_data);
    my $broker_code  = $decoded_data->{broker_code};
    $decoded_data->{client_loginid} = $loginid;

    push @{$landing_company_data{$broker_code}}, $decoded_data;
}

my $list_ip_mismatch_email;
BOM::Backoffice::Request::template()->process(
    "backoffice/mismatch_ip_records.html.tt",
    {
        all_data => \%landing_company_data,
    },
    \$list_ip_mismatch_email
) || die BOM::Backoffice::Request::template()->error();

my $brands = BOM::Config->brand();

send_email({
    from                  => $brands->emails('no-reply'),
    to                    => $brands->emails('compliance_alert'),
    subject               => 'IP Address Mismatch - ' . Date::Utility->new()->date(),
    message               => [$list_ip_mismatch_email,],
    email_content_is_html => 1,
});

# clear redis after sending email.
$redis->del(REDIS_MASTERKEY);
$redis->del(REDIS_TRACK_CHECKED);

1;
