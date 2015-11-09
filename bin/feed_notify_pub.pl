#!/usr/bin/perl
use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Try::Tiny;
use RedisDB;
use JSON;
use BOM::Database::FeedDB;

while (1) {
    try {
        my $redis = _redis();
        my $dbh   = BOM::Database::FeedDB::write_dbh();

        $dbh->do("LISTEN feed_watchers");

        my $sel = IO::Select->new;
        $sel->add($dbh->{pg_socket});
        while ($sel->can_read) {
            while (my $notify = $dbh->pg_notifies) {
                my ($name, $pid, $payload) = @$notify;
                _publish($redis, _msg($payload));
            }
        }
    }
    catch {
        warn "$0 ($$): saw exception: $_";
        sleep 1;
    };
}
exit;

sub _publish {
    my $redis = shift;
    my $msg   = shift;

    $redis->publish('FEED::' . $msg->{type}. '_'.$msg->{underlying}, JSON::to_json($msg));

}

sub _msg {
    my $payload = shift;

    my %msg;
    if ($payload =~ /tick/) {
        @msg{qw/type underlying ts spot/} = split(',', $payload);
    } else {
        @msg{qw/type underlying ts open high low close/} = split(',', $payload);
    }

    return \%msg;
}

sub _redis {
    my $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}
