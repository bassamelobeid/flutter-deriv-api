use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Fatal qw(dies_ok);
use Test::MockModule;
use BOM::TradingPlatform;
use BOM::Config::Runtime;

my $dxconfig = BOM::Config::Runtime->instance->app_config->system->dxtrade;
$dxconfig->suspend->all(0);
$dxconfig->suspend->demo(0);

my $dxtrader = BOM::TradingPlatform->new(
    platform => 'dxtrade',
);

my $mock_platform = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
my $mock_http     = Test::MockModule->new('HTTP::Tiny');
my $mock_time     = Test::MockModule->new('Time::HiRes');

my (@stats, @timing);
$mock_platform->redefine(
    stats_inc    => sub { push @stats,  \@_ },
    stats_timing => sub { push @timing, \@_ });
$mock_http->redefine(
    post => {
        headers => {timing => 1.23},
        success => 1,
    });
$mock_time->redefine(tv_interval => 0.002);

$dxtrader->call_api(
    server => 'demo',
    method => 'dummy',
);

cmp_deeply(
    \@timing,
    [['devexperts.rpc_service.timing', num((0.002 * 1000) - 1.23), {'tags' => bag('server:demo', 'method:dummy')}]],
    'expected stats_timing'
);

$mock_http->redefine(post => sub { die });

dies_ok {
    $dxtrader->call_api(
        server => 'demo',
        method => 'dummy',
    );
}
'call dies on failure';

cmp_deeply(\@stats, [['devexperts.rpc_service.api_call_fail', {'tags' => bag('server:demo', 'method:dummy')}]], 'expected stats_timing');

done_testing();
