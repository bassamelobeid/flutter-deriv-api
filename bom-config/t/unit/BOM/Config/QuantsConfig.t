use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Date::Utility;
use BOM::Config::QuantsConfig;
use Data::Dumper;

subtest 'save_config' => sub {
    my ($mocked_chronicle_reader, $mocked_chronicle_writer, $mocked_date_utility);
    my ($mocked_chronicle_reader_values);
    my $expected;
    $mocked_chronicle_reader = Test::MockObject->new();
    $mocked_chronicle_writer = Test::MockObject->new();
    $mocked_date_utility     = Date::Utility->new(12);
    $mocked_chronicle_reader->mock("get" => sub { return $mocked_chronicle_reader_values });
    $mocked_chronicle_writer->mock("set" => sub { return });
    my $mocked_quants_config = BOM::Config::QuantsConfig->new(
        chronicle_reader => $mocked_chronicle_reader,
        chronicle_writer => $mocked_chronicle_writer,
        recorded_date    => $mocked_date_utility        #this could be mocked or not depending on the test
    );
    my $config_type = "invalid_config_type";
    $expected = 'unregconized config type \[' . $config_type . '\]';
    throws_ok { $mocked_quants_config->save_config($config_type) } qr/$expected/, "Invalid config type is specified";

    $config_type = "custom_multiplier_commission";
    $expected    = {
        "contract_type" => 'CALL,PUT',
        "commission"    => 0.2
    };
    my $config = $expected;
    is_deeply($mocked_quants_config->save_config($config_type, $config), $expected, "contract type is custom_multiplier_commission");

    subtest '_process_commission_config' => sub {

        $config_type = "commission";

        $expected                       = 'name is required';
        $mocked_chronicle_reader_values = {};
        $config                         = {};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "name is not specified";

        $expected                       = 'name should only contain words and integers';
        $mocked_chronicle_reader_values = {};
        $config                         = {"name" => "\%#"};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "illegal name format";

        $expected                       = 'Cannot use an identical name';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {"name"     => "existing"};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "same name config should not exist";

        $expected                       = 'start_time is required';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {"name"     => "new"};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "start_time should be specified";

        $expected                       = 'end_time is required';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {
            "name"       => "new",
            "start_time" => 1
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "end_time should be specified";

        $expected                       = 'start time must be before end time';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {
            "name"       => "new",
            "start_time" => 1,
            "end_time"   => 1,
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "start time must be before end time";

        $expected                       = 'invalid input for ITM';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {
            "name"       => "new",
            "start_time" => 1,
            "end_time"   => 2,
            "ITM"        => "something"
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Invalid input for specific key";

        $expected                       = 'Invalid start_time format';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {
            "name"       => "new",
            "start_time" => "wrong format",
            "end_time"   => 2,
            "ITM"        => "something"
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Time format specified is incorrect";

        $expected                       = 'invalid input for contract_type \[something\]';
        $mocked_chronicle_reader_values = {"existing" => 1};
        $config                         = {
            "name"          => "new",
            "start_time"    => 1,
            "end_time"      => 2,
            "contract_type" => "something"
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Invalid input for contract_type or underlying_symbol";

    };
    $config_type = "commission";
    $expected    = {
        "name"          => "a",
        "start_time"    => 1234,
        "end_time"      => 34509,
        "contract_type" => ['CALL', 'PUT']};
    $mocked_chronicle_reader_values = {};
    $config                         = {
        "name"          => "a",
        "start_time"    => 1234,
        "end_time"      => 34509,
        "contract_type" => 'CALL,PUT'
    };
    is_deeply($mocked_quants_config->save_config($config_type, $config), $expected, "commission config is saved successfully");

    subtest '_process_multiplier_config' => sub {
        $config_type                    = 'maltainvest multiplier_config';
        $mocked_chronicle_reader_values = {};

        $expected = 'Commission for Malta Invest cannot be more than 0.1%';
        $config   = {"commission" => 0.1};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Maltainvest commission is not valid";

        $expected = 'multiplier range and stop out level definition does not match';
        $config   = {
            "commission"     => 0.0001,
            "stop_out_level" => {
                "30" => 0,
                "20" => 1
            },
            "multiplier_range" => ["30"]};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Multiplier range and stop out level does not match";

        $expected = 'stop out level is out of range. Allowable range from 0 to 70';
        $config   = {
            "name"           => "a",
            "start_time"     => 1234,
            "end_time"       => 34509,
            "commission"     => 0.0001,
            "stop_out_level" => {
                "30" => -10,
                "20" => 80
            },
            "multiplier_range" => ["30", "20"]};
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Stop out level is out of range";

        $expected = 'only \'d\'  unit and integer number of days are allowed';
        $config   = {
            "commission"     => 0.0001,
            "stop_out_level" => {
                "30" => 10,
                "20" => 60
            },
            "multiplier_range" => ["30", "20"],
            "expiry"           => "ad"
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "No integer specified in expiry duration";

        $expected = 'expiry has to be greater than 1d';
        $config   = {
            "commission"     => 0.0001,
            "stop_out_level" => {
                "30" => 10,
                "20" => 60
            },
            "multiplier_range" => ["30", "20"],
            "expiry"           => "0d"
        };
        throws_ok { $mocked_quants_config->save_config($config_type, $config) } qr/$expected/, "Expiry duration less than a day";
    };

    $config_type = "multiplier_config";
    $config      = {
        "commission"     => 0.0001,
        "stop_out_level" => {
            "30" => 10,
            "20" => 60
        },
        "multiplier_range" => ["30", "20"],
        "expiry"           => "3d"
    };
    $mocked_chronicle_reader_values = {};
    $expected                       = $config;
    is_deeply($mocked_quants_config->save_config($config_type, $config), $expected, "multiplier config is saved successfully");

    $config_type = "callputspread_barrier_multiplier";
    $config      = {
        "middle" => 0.1,
        "wide"   => 1
    };
    $expected = $config;
    is_deeply($mocked_quants_config->save_config($config_type, $config), $expected, "callputspread_barrier_multiplier config saved successfully");

    $config_type = "deal_cancellation";
    $config      = {
        underlying_symbol    => 'R_100',
        landing_companies    => 'virtual',
        dc_types             => '5m,10m,15m',
        start_datetime_limit => "2020-09-12T00:00:00",
        end_datetime_limit   => "2020-09-13T00:00:00",
        dc_comment           => "test create"
    };
    $expected = $config;
    is_deeply($mocked_quants_config->save_config($config_type, $config), $expected, "deal_cancellation config saved successfully");
};

subtest 'delete_config' => sub {
    my ($mocked_chronicle_reader, $mocked_chronicle_writer, $mocked_date_utility);
    my ($mocked_chronicle_reader_values);
    my $expected;
    $mocked_chronicle_reader = Test::MockObject->new();
    $mocked_chronicle_writer = Test::MockObject->new();
    $mocked_date_utility     = Date::Utility->new(12);
    $mocked_chronicle_reader->mock("get" => sub { return $mocked_chronicle_reader_values });
    $mocked_chronicle_writer->mock("set" => sub { return });
    my $mocked_quants_config = BOM::Config::QuantsConfig->new(
        chronicle_reader => $mocked_chronicle_reader,
        chronicle_writer => $mocked_chronicle_writer,
        recorded_date    => $mocked_date_utility        #this could be mocked or not depending on the test
    );

    my $config_type = "multiplier_config";
    my $name        = "frxEURGBP";
    $mocked_chronicle_reader_values = {};
    $expected                       = 'config does not exist config_type \[' . $config_type . '\] name \[' . $name . '\]';
    throws_ok { $mocked_quants_config->delete_config($config_type, $name) } qr/$expected/, "Config does not exist for deletion";

    $name                           = "frxEURGBP";
    $mocked_chronicle_reader_values = {
        "frxEURGBP" => {
            "multiplier_range"            => [30],
            "commission"                  => 0.003,
            "cancellation_commission"     => 0.05,
            "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
            "stop_out_level"              => {"30" => 0}}};
    $expected = {
        "multiplier_range"            => [30],
        "commission"                  => 0.003,
        "cancellation_commission"     => 0.05,
        "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
        "stop_out_level"              => {"30" => 0}};
    is_deeply($mocked_quants_config->delete_config($config_type, $name), $expected, "config deleted successfully");

};
subtest 'custom_deal_cancellation' => sub {
    my ($mocked_chronicle_reader, $mocked_chronicle_writer, $mocked_date_utility);
    my ($mocked_chronicle_reader_values);
    my $expected;
    $mocked_chronicle_reader = Test::MockObject->new();
    $mocked_chronicle_writer = Test::MockObject->new();
    $mocked_date_utility     = Date::Utility->new(12);
    $mocked_chronicle_reader->mock("get" => sub { return $mocked_chronicle_reader_values });
    $mocked_chronicle_writer->mock("set" => sub { return });
    my $mocked_quants_config = BOM::Config::QuantsConfig->new(
        chronicle_reader => $mocked_chronicle_reader,
        chronicle_writer => $mocked_chronicle_writer,
        recorded_date    => $mocked_date_utility        #this could be mocked or not depending on the test
    );
    my $lc                = "ao";
    my $underlying_symbol = "R_50";
    $mocked_chronicle_reader_values = {
        "R_50_ao" => {
            "dc_types"             => "5m,10m,15m",
            "start_datetime_limit" => 10,
            "end_datetime_limit"   => 20,
        }};
    my $date_pricing = 15;
    $expected = ["5m", "10m", "15m"];
    is_deeply($mocked_quants_config->custom_deal_cancellation($underlying_symbol, $lc, $date_pricing),
        $expected, "Sucessfully returns custom_deal_cancellation");

    $date_pricing = 25;
    $expected     = 0;
    is($mocked_quants_config->custom_deal_cancellation($underlying_symbol, $lc, $date_pricing), $expected, "date_pricing not satisfied");
};

subtest 'get_multiplier_config' => sub {
    my ($mocked_chronicle_reader, $mocked_chronicle_writer, $mocked_date_utility);
    my ($mocked_chronicle_reader_values, $mocked_default_config);
    my $expected;
    $mocked_chronicle_reader = Test::MockObject->new();
    $mocked_chronicle_writer = Test::MockObject->new();
    $mocked_date_utility     = Date::Utility->new(12);
    $mocked_chronicle_reader->mock("get" => sub { return $mocked_chronicle_reader_values });
    $mocked_chronicle_writer->mock("set" => sub { return });
    my $mocked_quants = Test::MockModule->new("BOM::Config::QuantsConfig");
    $mocked_quants->redefine("get_multiplier_config_default" => sub { return $mocked_default_config });
    my $mocked_quants_config = BOM::Config::QuantsConfig->new(
        chronicle_reader => $mocked_chronicle_reader,
        chronicle_writer => $mocked_chronicle_writer,
        recorded_date    => $mocked_date_utility        #this could be mocked or not depending on the test
    );
    my $mocked_quants_config_package = Test::MockModule->new(ref($mocked_quants_config))->redefine("for_date" => sub { return 0 });

    my $lc                = "maltainvest";
    my $underlying_symbol = "RF_50";

    $mocked_default_config = {$lc => {}};
    $expected              = {};
    is_deeply($mocked_quants_config->get_multiplier_config($lc, $underlying_symbol), $expected, "Default config is absent");

    $mocked_chronicle_reader_values = 0;
    $mocked_default_config          = {
        $lc => {
            $underlying_symbol => {
                "multiplier_range"            => [30],
                "commission"                  => 0.003,
                "cancellation_commission"     => 0.05,
                "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
                "stop_out_level"              => {"30" => 0}}}};
    $expected = {
        "multiplier_range"            => [30],
        "commission"                  => 0.003,
        "cancellation_commission"     => 0.05,
        "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
        "stop_out_level"              => {"30" => 0}};
    is_deeply($mocked_quants_config->get_multiplier_config($lc, $underlying_symbol), $expected, "Existing config is absent");

    $mocked_default_config = {
        $lc => {
            $underlying_symbol => {
                "multiplier_range"            => [30],
                "commission"                  => 0.003,
                "cancellation_commission"     => 0.05,
                "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
                "stop_out_level"              => {"30" => 0}}}};
    $mocked_chronicle_reader_values = {
        "cancellation_commission" => 1,
        "stop_out_level"          => {"40" => 0}};
    $expected = {
        "multiplier_range"            => [30],
        "commission"                  => 0.003,
        "cancellation_commission"     => 1,
        "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
        "stop_out_level"              => {"40" => 0}};
    is_deeply($mocked_quants_config->get_multiplier_config($lc, $underlying_symbol), $expected, "Default and Existing configs are both present");
    $mocked_quants->unmock_all();
};

subtest 'get_config' => sub {
    my ($mocked_chronicle_reader,        $mocked_chronicle_writer, $mocked_date_utility, $mocked_underlying_symbol);
    my ($mocked_chronicle_reader_values, $mocked_default_config,   $mocked_assets_value, $mocked_quoted_currency_value);
    my $expected;
    $mocked_chronicle_reader  = Test::MockObject->new();
    $mocked_chronicle_writer  = Test::MockObject->new();
    $mocked_underlying_symbol = Test::MockObject->new();
    $mocked_date_utility      = Date::Utility->new(12);

    $mocked_chronicle_reader->mock("get" => sub { return $mocked_chronicle_reader_values });
    $mocked_chronicle_writer->mock("set" => sub { return });
    $mocked_underlying_symbol->mock("asset"           => sub { return $mocked_assets_value });
    $mocked_underlying_symbol->mock("quoted_currency" => sub { return $mocked_quoted_currency_value });

    my $mocked_quants    = Test::MockModule->new("BOM::Config::QuantsConfig");
    my $mocked_financial = Test::MockModule->new("Finance::Underlying")->redefine("by_symbol" => sub { return $mocked_underlying_symbol });
    $mocked_quants->redefine("get_multiplier_config_default" => sub { return $mocked_default_config });
    my $mocked_quants_config = BOM::Config::QuantsConfig->new(
        chronicle_reader => $mocked_chronicle_reader,
        chronicle_writer => $mocked_chronicle_writer,
        recorded_date    => $mocked_date_utility        #this could be mocked or not depending on the test
    );
    my $mocked_quants_config_package = Test::MockModule->new(ref($mocked_quants_config))->redefine("for_date" => sub { return 0 });

    $mocked_chronicle_reader_values = undef;
    my $config_type = "not_commission";
    $expected = {};
    is_deeply($mocked_quants_config->get_config($config_type), $expected, "Existing config is absent");

    $mocked_chronicle_reader_values = {
        "multiplier_range"            => [30],
        "commission"                  => 0.003,
        "cancellation_commission"     => 1,
        "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
        "stop_out_level"              => {"40" => 0}};
    $config_type = "not_commission";
    $expected    = {
        "multiplier_range"            => [30],
        "commission"                  => 0.003,
        "cancellation_commission"     => 1,
        "cancellation_duration_range" => ["5m", "10m", "15m", "30m", "60m"],
        "stop_out_level"              => {"40" => 0}};
    is_deeply($mocked_quants_config->get_config($config_type), $expected, "Existing config is present");

    $mocked_chronicle_reader_values = {
        "A" => {
            "bias"              => "short",
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => []
        },
        "B" => {
            "bias"              => "long",
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => []}};
    $config_type = "commission";
    $expected    = [{
            "bias"              => "short",
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => []
        },
        {
            "bias"              => "long",
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => []}];
    cmp_bag($mocked_quants_config->get_config($config_type), $expected, "Additional args are not provided");

    $mocked_chronicle_reader_values = {
        "A" => {
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => ["INR", "AED"]
        },
        "B" => {
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => []}};
    $config_type = "commission";
    my $args = {"underlying_symbol" => "INR"};
    $expected = [{
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => ["INR", "AED"]
        },
    ];
    cmp_bag($mocked_quants_config->get_config($config_type, $args), $expected, "Filter via underlying symbol without bias");

    $mocked_chronicle_reader_values = {
        "A" => {
            "bias"              => "short",
            "contract_type"     => "PUT",
            "underlying_symbol" => [],
            "currency_symbol"   => ["INR", "AED"]
        },
        "B" => {
            "bias"              => "long",
            "contract_type"     => "CALL",
            "underlying_symbol" => [],
            "currency_symbol"   => ["INR"]}};
    $config_type = "commission";
    $args        = {
        "underlying_symbol" => "frx_",
        "contract_type"     => "PUT"
    };
    $mocked_assets_value          = "INR";
    $mocked_quoted_currency_value = "AED";
    $expected                     = [{
            "bias"              => "short",
            "contract_type"     => "PUT",
            "underlying_symbol" => [],
            "currency_symbol"   => ["INR", "AED"]
        },
    ];
    cmp_bag($mocked_quants_config->get_config($config_type, $args), $expected, "Filter via currency symbols with bias");

};

done_testing;
