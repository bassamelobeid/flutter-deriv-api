#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 2;
use Test::MockModule;
use Test::NoWarnings ();
use Test::Exception;

use BOM::Platform::Sysinit;

BEGIN {
    package Test::Request;

    use strict;
    use warnings;

    my $r = bless {} => __PACKAGE__;

    sub new {
        return $r;
    }

    sub from_ui {
        return 1;
    }

    sub backoffice {
        return 0;
    }

    sub loginid {
        return 'DUMMY';
    }

    sub http_handler {
        $_[0]->{http_handler} = $_[1];
        return;
    }
}

BEGIN {
    package Test::AppRequest;

    use strict;
    use warnings;

    my $r = bless {} => __PACKAGE__;

    sub new {
        return $r;
    }

    sub register_cleanup {
        push @{$r->{cleanup}}, $_[1];
        return;
    }

    sub cleanups {
        return $r->{cleanup};
    }
}

subtest 'reset redis connections at end of request', sub {
    my $mock1 = Test::MockModule->new('BOM::Platform::Sysinit');
    $mock1->mock(request => \&Test::Request::new);
    $mock1->mock(build_request => sub {});
    my $mock2 = Test::MockModule->new('Plack::App::CGIBin::Streaming');
    $mock2->mock(request => \&Test::AppRequest::new);

    BOM::Platform::Sysinit::init;

    is 0+@{Test::AppRequest::cleanups || []}, 1, 'got 1 cleanup';

    note "rendering Cache::RedisDB connection unusable";

    Cache::RedisDB->set(MY => 'k2', 19);

    Cache::RedisDB->redis->send_command(GET => 'MY::k1');
    throws_ok {
        Cache::RedisDB->get(MY => 'k2');
    } qr/when you have replies to fetch/, 'Cache::RedisDB connection is now unusable';

    note "rendering Chronicle connections unusable";

    BOM::System::Chronicle->_redis_write->set('MY::k1', 23);
    BOM::System::Chronicle->_redis_write->send_command(GET => 'MY::k1');
    BOM::System::Chronicle->_redis_read->send_command(GET => 'MY::k1');

    throws_ok {
        BOM::System::Chronicle->_redis_write->get('MY::k1');
    } qr/when you have replies to fetch/, 'BOM::System::Chronicle->_redis_write connection is now unusable';

    throws_ok {
        BOM::System::Chronicle->_redis_read->get('MY::k1');
    } qr/when you have replies to fetch/, 'BOM::System::Chronicle->_redis_read connection is now unusable';

    note "running cleanups";

    Test::AppRequest::cleanups->[0]->();

    note "checking usability after cleanup";

    lives_ok {
        is +Cache::RedisDB->get(MY => 'k2'), 19, 'got expected value';
    } 'Cache::RedisDB connection has become usable again';

    lives_ok {
        is +BOM::System::Chronicle->_redis_read->get('MY::k1'), 23, 'got expected value';
    } 'BOM::System::Chronicle->_redis_read connection has become usable again';

    lives_ok {
        is +BOM::System::Chronicle->_redis_write->get('MY::k1'), 23, 'got expected value';
    } 'BOM::System::Chronicle->_redis_write connection has become usable again';
};

Test::NoWarnings::had_no_warnings;
