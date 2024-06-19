use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

use BOM::MT5::User::Async;

use Guard;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
my $parallel_run_key = 'system.mt5.parallel_run';
my $proxy_key        = 'system.mt5.http_proxy.demo.p01_ts01';

scope_guard {
    $app_config->set({
        $parallel_run_key => $app_config->system->mt5->parallel_run,
        $proxy_key        => $app_config->system->mt5->http_proxy->demo->p01_ts01,
    });
};

subtest 'Default config for parallel run is disabled' => sub {
    is(BOM::MT5::User::Async::_is_parallel_run_enabled, 0, 'parallel_run disabled by default');
};

subtest 'Zero for disabled' => sub {
    $app_config->set({$parallel_run_key, 0});

    is(BOM::MT5::User::Async::_is_parallel_run_enabled, 0, 'parallel_run returns zero (disabled)');
};

subtest 'Enable Parallel run' => sub {
    $app_config->set({$parallel_run_key, 1});

    is(BOM::MT5::User::Async::_is_parallel_run_enabled, 1, 'parallel_run returns 1 (enabled)');
};

subtest 'Combine parallel_run with enabled http proxy config, and RO/RW calls' => sub {
    my $mocked_async = Test::MockModule->new('BOM::MT5::User::Async');
    my $proxy_called = 0;
    my $php_called   = 0;

    $mocked_async->mock(
        '_invoke_using_proxy',
        sub {
            $proxy_called++;
            return Future->done('proxy');
        });

    $mocked_async->mock(
        '_invoke_using_php',
        sub {
            $php_called++;
            return Future->done('php');
        });

    subtest 'Disabled parallel and disabled proxy' => sub {
        $app_config->set({$parallel_run_key, 0});
        $app_config->set({$proxy_key,        0});
        $proxy_called = 0;
        $php_called   = 0;

        BOM::MT5::User::Async::_invoke('UserAdd', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 0, 'Proxy is not called for disabled parallel and disabled proxy, write call');
        is($php_called,   1, 'PHP is called for disabled parallel and disabled proxy, write call');

        BOM::MT5::User::Async::_invoke('GroupGet', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 0, 'Proxy is not called for disabled parallel and disabled proxy, read-only call');
        is($php_called,   2, 'PHP is called for disabled parallel and disabled proxy, read-only call');
    };

    subtest 'Disabled parallel and enabled proxy' => sub {
        $app_config->set({$parallel_run_key, 0});
        $app_config->set({$proxy_key,        1});
        $proxy_called = 0;
        $php_called   = 0;

        BOM::MT5::User::Async::_invoke('UserAdd', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 1, 'Proxy is called for disabled parallel and enabled proxy, write call');
        is($php_called,   0, 'PHP is not called for disabled parallel and enabled proxy, write call');

        BOM::MT5::User::Async::_invoke('GroupGet', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 2, 'Proxy is  called for disabled parallel and enabled proxy, read-only call');
        is($php_called,   0, 'PHP is not called for disabled parallel and enabled proxy, read-only call');
    };

    subtest 'Enabled parallel and disabled proxy' => sub {
        $app_config->set({$parallel_run_key, 1});
        $app_config->set({$proxy_key,        0});
        $proxy_called = 0;
        $php_called   = 0;

        BOM::MT5::User::Async::_invoke('UserAdd', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 0, 'Proxy is not called for enabled parallel and disabled proxy, write call');
        is($php_called,   1, 'PHP is not called for enabled parallel and disabled proxy, write call');

        BOM::MT5::User::Async::_invoke('GroupGet', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 0, 'Proxy is not called for enabled parallel and disabled proxy, read-only call');
        is($php_called,   2, 'PHP is not called for enabled parallel and disabled proxy, read-only call');
    };

    subtest 'Enabled parallel and enabled proxy' => sub {
        $app_config->set({$parallel_run_key, 1});
        $app_config->set({$proxy_key,        1});
        $proxy_called = 0;
        $php_called   = 0;

        BOM::MT5::User::Async::_invoke('UserAdd', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 0, 'Proxy is not called for enabled parallel and enabled proxy, write call');
        is($php_called,   1, 'PHP is not called for enabled parallel and enabled proxy, write call');

        my $ret = BOM::MT5::User::Async::_invoke('GroupGet', 'demo', 'p01_ts01', 'MTD', {})->get();

        is($proxy_called, 1,     'Proxy is called for enabled parallel and enabled proxy, read-only call');
        is($php_called,   2,     'PHP is not called for enabled parallel and enabled proxy, read-only call');
        is($ret,          'php', 'PHP script returns data even if proxy was called');
    };
};

done_testing();
