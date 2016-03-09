use Test::Most 0.22 (tests => 4);
use Test::Warn;

use BOM::Platform::Runtime::AppConfig;
use BOM::Platform::Runtime;

my $app_config;
lives_ok {
    $app_config = BOM::Platform::Runtime::AppConfig->new();
}
'We are living';

ok($app_config->system->isa('BOM::Platform::Runtime::AppConfig::Attribute::Section'), 'system is a Section');
is($app_config->system->send_email_to_clients, 0, "send_email_to_clients is 0");
is_deeply($app_config->quants->underlyings->suspend_trades, [], "suspendonlytrades is empty by default");
