#!/etc/rmg/bin/perl

=head1 NAME

cron_report_ip_mismatch.pl

=head1 DESCRIPTION

This is a CRON script to report any mismatch of ip address country and client's residence

=cut

package main;
use strict;
use warnings;

use Brands;
use BOM::Backoffice::Request;
use BOM::Platform::Email qw(send_email);
use JSON::MaybeXS qw{decode_json};
use Date::Utility;
use LandingCompany::Registry;
use BOM::Config::RedisReplicated;
use BOM::User::Client;
use BOM::User;
use Cache::RedisDB;

use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

my $redis = BOM::Config::RedisReplicated::redis_write;
use constant REDIS_MASTERKEY => 'IP_COUNTRY_MISMATCH';
my @allkeys = @{$redis->hkeys(REDIS_MASTERKEY)};
my @compiled_data;

my %mt5_checks = map { $_ => 1 } LandingCompany::Registry::get_mt5_check_broker_codes();

# get the list of MT5 accounts, check if any of them
# This check checks if the account have any 'real\vanautu_standard' MT5 account.
sub mt5_check_real_vanuatu {
    my ($loginid, $broker_code) = @_;
    return 1 unless exists $mt5_checks{$broker_code};

    # not sending any values into mt5_logins will not trigger call to MT5 server
    my @mt5_list = BOM::User->new(loginid => $loginid)->mt5_logins('');

    my $check_flag;
    if (@mt5_list) {
        for (@mt5_list) {
            $_ =~ s/[A-Z]+//g;
            my $mt5_group = Cache::RedisDB->get('MT5_USER_GROUP', $_);
            Cache::RedisDB->redis->lpush('MT5_USER_GROUP_PENDING', join(':', $_, time)) unless defined $mt5_group;
            $mt5_group //= 'unknown';
            $check_flag = 1 if ($mt5_group eq 'real\vanuatu_standard');
            last if ($check_flag);
        }
    }
    return $check_flag;
}

my %lc_data;

foreach my $loginid (@allkeys) {
    my $each_data = decode_json $redis->hget(REDIS_MASTERKEY, $loginid);
    next unless mt5_check_real_vanuatu($loginid, $each_data->{broker_code});
    $each_data->{client_loginid} = $loginid;
    push @{$lc_data{$each_data->{broker_code}}}, $each_data;
}

my $list_ip_mismatch_email;
BOM::Backoffice::Request::template()->process(
    "backoffice/mismatch_ip_records.html.tt",
    {
        all_data => \%lc_data,
    },
    \$list_ip_mismatch_email
) || die BOM::Backoffice::Request::template()->error();

my $brands = Brands->new();

send_email({
    from                  => $brands->emails('system'),
    to                    => $brands->emails('compliance_alert'),
    subject               => 'IP Address Mismatch - ' . Date::Utility->new()->date(),
    message               => [$list_ip_mismatch_email,],
    email_content_is_html => 1,
});

# clear redis after sending email.
$redis->del(REDIS_MASTERKEY);
