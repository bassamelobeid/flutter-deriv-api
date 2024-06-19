use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Data::Dump 'pp';
use feature 'say';
use BOM::Test;
use Net::Async::Redis;

require "/home/git/regentmarkets/bom-backoffice/subs/subs_backoffice_clientdetails.pm";

my $loop = IO::Async::Loop->new;

$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => BOM::Config::Redis::redis_config('mt5_user', 'write')->{uri},
    ));

sub begin_tests {
    $redis->hmset(
        "MT5_USER_GROUP::MTD000001",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000001");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000002",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000002");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000003",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000003");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000004",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000004");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000005",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000005");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000006",
        (
            'group'  => 'demo\\p01_ts01\\synthetic\\svg_std_usd',
            'rights' => '481',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000006");
            ok($group =~ m/demo/, "User is active");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000007",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000007");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000008",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000008");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000009",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000009");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000010",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000010");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000011",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000011");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000012",
        (
            'group'  => 'Archived',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000012");
            ok($group =~ 'Archived', "User is archived");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000013",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000013");
            ok($group =~ 'Deleted', "User is deleted");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000014",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000014");
            ok($group =~ 'Deleted', "User is deleted");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000015",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000015");
            ok($group =~ 'Deleted', "User is deleted");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000016",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000016");
            ok($group =~ 'Deleted', "User is deleted");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000017",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000017");
            ok($group =~ 'Deleted', "User is deleted");
        });

    $redis->hmset(
        "MT5_USER_GROUP::MTD000018",
        (
            'group'  => 'Deleted',
            'rights' => '4',
        )
    )->on_done(
        sub {
            my ($group, $status) = get_mt5_group_and_status("MTD000018");
            ok($group =~ 'Deleted', "User is deleted");
        });

}

begin_tests->get;

done_testing();

