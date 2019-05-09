#!/usr/bin/env perl 
use strict;
use warnings;

=head1 NAME

C<mt5_group_caching.pl>

=head1 DESCRIPTION

Processes MT5 group requests from the backoffice
and caches the information in Redis.

=cut

use IO::Async::Loop;

use Net::Async::Redis;
use Future::Utils qw(repeat);

use BOM::Config::Runtime;
use BOM::Config::RedisReplicated;
use BOM::MT5::User::Async;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';

my $loop = IO::Async::Loop->new;
$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => BOM::Config::RedisReplicated::redis_config('mt5_user', 'write')->{uri},
    ));

sub is_mt5_suspended {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    return 1 if $app_config->system->suspend->mt5;
    return 0;
}

sub group_for_user {
    my ($id) = @_;
    return BOM::MT5::User::Async::get_user($id)->transform(
        done => sub {
            shift->{group};
        });
}

(
    repeat {
        $redis->brpop('MT5_USER_GROUP_PENDING', 60000)->then(
            sub {
                my ($queue, $job) = @{$_[0]};
                my ($id, $queued) = split /:/, $job;
                $log->debugf('Processing pending ID [%s]', $id);
                my $cache_key = 'MT5_USER_GROUP::' . $id;
                $redis->get($cache_key)->then(
                    sub {
                        my ($group) = @_;

                        if ($group) {
                            $log->debugf('Existing group found for ID [%s] - %s', $id, $group);
                            return Future->done;
                        }

                        # We avoid the MT5 call if it's suspended, but also pause for
                        # a bit - no need to burn through the queue
                        # too quickly if it's only down temporarily
                        return $loop->delay_future(after => 60) if is_mt5_suspended();

                        group_for_user($id)->else(
                            sub {
                                $log->errorf('Failure when retrieving group for [%s] - %s', $id, [@_]);
                                Future->done('failed to get group');
                            }
                            )->then(
                            sub {
                                my ($group) = @_;
                                # Keep things around for a week,
                                # long enough to be useful but
                                # try not to keep bad data too long...
                                # but 5 minutes is good enough for
                                # a negative cache.
                                my $ttl = $group ? 7 * 86400 : 300;
                                $group //= 'unknown';
                                $redis->set(
                                    $cache_key => $group,
                                    EX         => $ttl,
                                    )->on_done(
                                    sub {
                                        $log->infof('Cached ID [%s] group [%s]', $id, $group);
                                    });
                            });
                    });
            }
            )->on_fail(
            sub {
                $log->errorf('Failure - %s', [@_]);
            })
    }
    while => sub {
        1;
    })->get;

