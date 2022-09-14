use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;

use BOM::Config::Runtime;

subtest 'get_offerings_config' => sub {
    my ($expected,                                 $input);
    my ($mocked_underlyings_suspend_buy_values,    $mocked_underlyings_suspend_trades_values);
    my ($mocked_contract_types_suspend_buy_values, $mocked_contract_types_suspend_trades_values);
    my ($mocked_market_suspend_buy_values,         $mocked_market_suspend_trades_values);
    my ($mocked_system_suspend_trading_value,      $mocked_loaded_revision_value);

    my $instance                     = BOM::Config::Runtime->instance;
    my $mocked_instance              = Test::MockModule->new(ref $instance);
    my $mocked_app_config            = Test::MockObject->new();
    my $mocked_system                = Test::MockObject->new();
    my $mocked_system_suspend        = Test::MockObject->new();
    my $mocked_quants                = Test::MockObject->new();
    my $mocked_quants_underlyings    = Test::MockObject->new();
    my $mocked_quants_markets        = Test::MockObject->new();
    my $mocked_quants_contract_types = Test::MockObject->new();

    $mocked_instance->redefine("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("system"          => sub { return $mocked_system });
    $mocked_app_config->mock("loaded_revision" => sub { return $mocked_loaded_revision_value });
    $mocked_app_config->mock("quants"          => sub { $mocked_quants });
    $mocked_system->mock("suspend" => sub { return $mocked_system_suspend });
    $mocked_system_suspend->mock("trading" => sub { return $mocked_system_suspend_trading_value });
    $mocked_quants->mock("underlyings"    => sub { return $mocked_quants_underlyings });
    $mocked_quants->mock("markets"        => sub { return $mocked_quants_markets });
    $mocked_quants->mock("contract_types" => sub { return $mocked_quants_contract_types });
    $mocked_quants_underlyings->mock("suspend_buy"    => sub { return $mocked_underlyings_suspend_buy_values });
    $mocked_quants_underlyings->mock("suspend_trades" => sub { return $mocked_underlyings_suspend_trades_values });
    $mocked_quants_markets->mock("suspend_buy"    => sub { return $mocked_market_suspend_buy_values });
    $mocked_quants_markets->mock("suspend_trades" => sub { return $mocked_market_suspend_trades_values });
    $mocked_quants_contract_types->mock("suspend_buy"    => sub { return $mocked_contract_types_suspend_buy_values });
    $mocked_quants_contract_types->mock("suspend_trades" => sub { return $mocked_contract_types_suspend_trades_values });

    $input    = "dont sell";
    $expected = 'unsupported action ' . $input;
    throws_ok { BOM::Config::Runtime->get_offerings_config($input) } qr/$expected/, "Invalid action is specified";

    $mocked_system_suspend_trading_value = 15;
    $mocked_loaded_revision_value        = 1;
    $expected                            = {
        loaded_revision => 0,
        action          => 'buy',
        suspend_trading => $mocked_system_suspend_trading_value
    };

    is_deeply(BOM::Config::Runtime->get_offerings_config("buy", 1), $expected, "Exclude suspend is enabled");

    $mocked_underlyings_suspend_buy_values       = ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10"];
    $mocked_underlyings_suspend_trades_values    = ["USDCHFDFX10", "EURUSDDFX100N"];
    $mocked_market_suspend_buy_values            = ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10"];
    $mocked_market_suspend_trades_values         = ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10"];
    $mocked_contract_types_suspend_buy_values    = ["USDJPYDFX10"];
    $mocked_contract_types_suspend_trades_values = ["GBPUSDDFX10"];
    $expected                                    = {
        loaded_revision            => $mocked_loaded_revision_value,
        action                     => 'buy',
        suspend_trading            => $mocked_system_suspend_trading_value,
        suspend_underlying_symbols => ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10", "EURUSDDFX100N"],
        suspend_markets            => ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10"],
        suspend_contract_types     => ["USDJPYDFX10", "GBPUSDDFX10"],
    };
    is_deeply(BOM::Config::Runtime->get_offerings_config("buy"), $expected, "Action is buy");

    $expected = {
        loaded_revision            => $mocked_loaded_revision_value,
        action                     => 'sell',
        suspend_trading            => $mocked_system_suspend_trading_value,
        suspend_underlying_symbols => ["USDCHFDFX10", "EURUSDDFX100N"],
        suspend_markets            => ["USDJPYDFX10", "GBPUSDDFX10", "USDCHFDFX10"],
        suspend_contract_types     => ["GBPUSDDFX10"],
    };
    is_deeply(BOM::Config::Runtime->get_offerings_config("sell"), $expected, "Action is sell");
};

done_testing();
