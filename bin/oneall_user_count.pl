#!/usr/bin/env perl 
use strict;
use warnings;

use Net::Async::HTTP;
use IO::Async::Loop;
use Future::AsyncAwait;
use JSON::MaybeUTF8 qw(:v1);
use HTTP::Cookies;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON::MaybeXS;
use YAML::XS;
use Log::Any          qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use POSIX             qw(strftime);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $loop = IO::Async::Loop->new;
my $jar  = HTTP::Cookies->new;
my $json = JSON::MaybeXS->new(pretty => 1);
my $cfg  = YAML::XS::LoadFile('/etc/rmg/third_party.yml')
    or die 'need a config.yml file';
$loop->add(
    my $ua = Net::Async::HTTP->new(
        cookie_jar               => $jar,
        max_connections_per_host => 4,
        max_in_flight            => 8,
        pipeline                 => 1,
        stall_timeout            => 30,
        fail_on_error            => 1,
        (
            $cfg->{socks}
            ? (map { ; "SOCKS_$_" => $cfg->{socks}{$_} } keys $cfg->{socks}->%*)
            : ()
        ),
    ));

for my $site ('binary', 'deriv') {
    my $date = strftime "%F", localtime(time() - 24 * 60 * 60 * 365);

    my ($res) = await $ua->GET(
        # https://docs.oneall.com/api/resources/users/list-all-users/
        'https://' . $site . '.api.oneall.com/users.json?page=1&entries_per_page=5&filters=date_last_login:gt:' . $date,
        headers => {Accept => 'application/json, text/plain, */*'},
        user    => $cfg->{oneall}{$site}{public_key},
        pass    => $cfg->{oneall}{$site}{private_key},
    );
    $log->debugf('Results are: %s', $res->content);
    my $data  = decode_json_utf8($res->content);
    my $count = $data->{response}{result}{data}{users}{pagination}{total_entries};
    $log->debugf('oneall.user.count=%d', $count);
    stats_gauge('oneall.user.count', $count, {tags => ['site:' . $site]});
}
