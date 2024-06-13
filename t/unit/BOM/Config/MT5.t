use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use BOM::Config;
use BOM::Config::MT5;
use BOM::Config::Runtime;
use Data::Printer;

subtest 'create_server_structure' => sub {
    my $input;
    my $expected;

    $input    = ["server", "", "server_type", "large"];
    $expected = undef;
    is(BOM::Config::MT5::create_server_structure(@$input), $expected, "server is not specified");

    $input    = ["server_type", "", "server", "large"];
    $expected = undef;
    is(BOM::Config::MT5::create_server_structure(@$input), $expected, "server_type is not specified");

    $input = [
        "server",
        {
            "geolocation" => {
                "location" => "EUROPE",
                "region"   => "NORTH",
                "sequence" => "123",
                "group"    => "test"
            },
            "environment" => "prod"
        },
        "server_type",
        "Large"
    ];
    $expected = {
        "Large" => {
            "geolocation" => {
                "location" => "EUROPE",
                "region"   => "NORTH",
                "sequence" => "123",
                "group"    => "test"
            },
            "environment" => "prod"
        }};
    is_deeply(BOM::Config::MT5::create_server_structure(@$input), $expected, "Server and server_type is specified");
};
subtest 'server_by_id' => sub {

    my $mocked_webapi_config;
    my $expected;
    my $mocked_MT5_fields;

    my $mocked_MT5 = Test::MockModule->new("BOM::Config::MT5");
    $mocked_MT5->redefine("new"           => sub { bless $mocked_MT5_fields, "BOM::Config::MT5" });
    $mocked_MT5->redefine("webapi_config" => sub { return $mocked_webapi_config });

    $mocked_MT5_fields = {
        "group"       => 'real\p01_ts01\synthetic\svg_std_usd\lol',
        "group_type"  => "real",
        "server_type" => "p01_ts01"
    };
    $mocked_webapi_config = {"real" => {"server_type" => ""}};
    my $mocked_MT5_object = BOM::Config::MT5->new();
    $expected = 'Cannot extract server information from group[' . $mocked_MT5_object->{group} . ']';
    throws_ok { $mocked_MT5_object->server_by_id() } qr/\Q$expected\E/, "Server group does not have required information";

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts01"
    };
    $mocked_webapi_config = {"real" => {"server_type" => ""}};
    $mocked_MT5_object    = BOM::Config::MT5->new();
    $expected =
          'Cannot extract server information from  server type['
        . $mocked_MT5_object->{server_type}
        . '] and group type['
        . $mocked_MT5_object->{group_type} . ']';
    throws_ok { $mocked_MT5_object->server_by_id() } qr/\Q$expected\E/, "Server type and group type does not have required information";

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts01"
    };
    $mocked_webapi_config = {
        "real" => {
            "p01_ts01" => {
                "geolocation" => {
                    "location" => "EUROPE",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                },
                "environment" => "prod"
            }}};
    $mocked_MT5_object = BOM::Config::MT5->new();
    $expected          = {
        "p01_ts01" => {
            "geolocation" => {
                "location" => "EUROPE",
                "region"   => "NORTH",
                "sequence" => "123",
                "group"    => "test"
            },
            "environment" => "prod"
        }};
    is_deeply($mocked_MT5_object->server_by_id(), $expected, "Fetches server by id correctly");
    $mocked_MT5->unmock_all();
};

subtest 'server_by_country' => sub {

    my $expected;

    $expected = "country code is requird";
    throws_ok { BOM::Config::MT5->server_by_country() } qr/$expected/, "Country code is not specified";

    my $mocked_MT5_fields;
    my $mocked_routing_config;
    my $mocked_webapi_config;
    my $mocked_MT5                               = Test::MockModule->new("BOM::Config::MT5");
    my $instance                                 = BOM::Config::Runtime->instance;
    my $mocked_instance                          = Test::MockModule->new(ref $instance);
    my $mocked_app_config                        = Test::MockObject->new();
    my $mocked_system                            = Test::MockObject->new();
    my $mocked_MT5_config                        = Test::MockObject->new();
    my $mocked_MT5_suspend                       = Test::MockObject->new();
    my $mocked_MT5_suspend_group_type            = Test::MockObject->new();
    my $mocked_MT5_suspend_group_type_server     = Test::MockObject->new();
    my $mocked_MT5_suspend_group_type_server_all = 1;
    my $mocked_MT5_suspend_all                   = 1;
    $mocked_MT5->redefine("new"            => sub { bless $mocked_MT5_fields, "BOM::Config::MT5" });
    $mocked_MT5->redefine("routing_config" => sub { return $mocked_routing_config });
    $mocked_MT5->redefine("webapi_config"  => sub { return $mocked_webapi_config });
    $mocked_instance->redefine("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("system" => sub { return $mocked_system });
    $mocked_system->mock("mt5" => sub { return $mocked_MT5_config });
    $mocked_MT5_config->mock("suspend" => sub { return $mocked_MT5_suspend });
    $mocked_MT5_suspend->mock("all"        => sub { return $mocked_MT5_suspend_all });
    $mocked_MT5_suspend->mock("group_type" => sub { return $mocked_MT5_suspend_group_type });
    $mocked_MT5_suspend_group_type->mock("server" => sub { return $mocked_MT5_suspend_group_type_server });
    $mocked_MT5_suspend_group_type_server->mock("all" => sub { return $mocked_MT5_suspend_group_type_server_all });

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts02"
    };
    $mocked_routing_config = {
        "real" => {
            "ao" => {
                "synthetic" => {
                    "servers" => {
                        "standard" => ['p01_ts02', 'p02_ts02'],
                    }
                },
                "financial" => {
                    "servers" => {
                        "standard" => ['p01_ts01'],
                    }}}}};
    $mocked_webapi_config = {
        "real" => {
            "p01_ts01" => {
                "environment" => "prod",
                "geolocation" => "UK"
            },
            "p01_ts02" => {
                "environment" => "prod",
                "geolocation" => "EU"
            },
            "p02_ts02" => {
                "environment" => "prod",
                "geolocation" => "US"
            }}};
    my $mocked_MT5_object = BOM::Config::MT5->new();
    $expected = {
        "real" => {
            "synthetic" => [{
                    "disabled"           => 1,
                    "environment"        => 'prod',
                    "geolocation"        => 'EU',
                    "id"                 => 'p01_ts02',
                    "recommended"        => 1,
                    "supported_accounts" => ['gaming']
                },
                {
                    "disabled"           => 1,
                    "environment"        => 'prod',
                    "geolocation"        => 'US',
                    "id"                 => 'p02_ts02',
                    "recommended"        => 0,
                    "supported_accounts" => ['gaming']}
            ],
            "financial" => [{
                    "disabled"           => 1,
                    "environment"        => 'prod',
                    "geolocation"        => 'UK',
                    "id"                 => 'p01_ts01',
                    "recommended"        => 1,
                    "supported_accounts" => ['gaming', 'financial', 'financial_stp', 'all']}]}};
    is_deeply(
        $mocked_MT5_object->server_by_country(
            "ao",
            {
                group_type           => 'real',
                sub_account_category => 'standard'
            }
        ),
        $expected,
        "Valid country code is specified"
    );
    $mocked_MT5->unmock_all();
};

subtest 'server' => sub {
    my $mocked_mt5 = Test::MockModule->new("BOM::Config::MT5");
    my $mocked_webapi_config;
    my $mocked_MT5_fields;
    my $mocked_MT5_object;
    my $expected;
    $mocked_mt5->redefine("new"           => sub { return bless $mocked_MT5_fields, "BOM::Config::MT5" });
    $mocked_mt5->redefine("webapi_config" => sub { return $mocked_webapi_config });
    $mocked_webapi_config = {
        "real" => {
            "p01_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }
            },
            "p01_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "EU",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }
            },
            "p02_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "US",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}
        },
        "demo" => {
            "p03_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }
            },
            "p03_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "EU",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}}};

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts02"
    };
    $expected = [{
            "p01_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}
        },
        {
            "p01_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "EU",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}
        },
        {
            "p02_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "US",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}}];
    $mocked_MT5_object = BOM::Config::MT5->new();
    is_deeply($mocked_MT5_object->servers(), $expected, "Server group type is real");

    $mocked_MT5_fields = {
        "group_type"  => "demo",
        "server_type" => "p01_ts02"
    };
    $expected = [{
            "p03_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}
        },
        {
            "p03_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "EU",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}}];
    $mocked_MT5_object = BOM::Config::MT5->new();
    is_deeply($mocked_MT5_object->servers(), $expected, "Server group type is demo");

    $mocked_MT5_fields    = {"group_type" => 0};
    $mocked_webapi_config = {
        "request_timeout" => {

        },
        "mt5_http_proxy_url" => {

        }};
    $expected          = [];
    $mocked_MT5_object = BOM::Config::MT5->new();
    is_deeply($mocked_MT5_object->servers(), $expected, "group type is request_timeout or mt5_http_proxy_url");
    $mocked_mt5->unmock_all();
};

subtest 'symmetrical_servers' => sub {
    my $mocked_MT5_fields;
    my $mocked_webapi_config;
    my $expected;
    my $mocked_MT5_object;
    my $mocked_MT5 = Test::MockModule->new("BOM::Config::MT5");
    $mocked_MT5->redefine("new"           => sub { return bless $mocked_MT5_fields, "BOM::Config::MT5" });
    $mocked_MT5->redefine("webapi_config" => sub { return $mocked_webapi_config });

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts02"
    };
    $mocked_webapi_config = {
        "real" => {
            "p01_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }
            },
            "p01_ts02" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "EU",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }}}};
    $expected = {
        "p01_ts02" => {
            "environment" => "prod",
            "geolocation" => {
                "location" => "EU",
                "region"   => "NORTH",
                "sequence" => "123",
                "group"    => "test"
            }}};
    $mocked_MT5_object = BOM::Config::MT5->new();
    is_deeply($mocked_MT5_object->symmetrical_servers(), $expected, "Symmetrical servers are fetched");

    $mocked_MT5_fields = {
        "group_type"  => "real",
        "server_type" => "p01_ts01"
    };
    $mocked_webapi_config = {
        "real" => {
            "p01_ts01" => {
                "environment" => "prod",
                "geolocation" => {
                    "location" => "UK",
                    "region"   => "NORTH",
                    "sequence" => "123",
                    "group"    => "test"
                }
            },
        }};
    $expected = {
        "p01_ts01" => {
            "environment" => "prod",
            "geolocation" => {
                "location" => "UK",
                "region"   => "NORTH",
                "sequence" => "123",
                "group"    => "test"
            }}};
    $mocked_MT5_object = BOM::Config::MT5->new();
    is_deeply($mocked_MT5_object->symmetrical_servers(), $expected, "Excpetion case is encountered");
    $mocked_MT5->unmock_all();
};

subtest 'available_groups' => sub {
    my $mocked_MT5 = Test::MockModule->new("BOM::Config::MT5");
    my $mocked_groups_config;
    my $mocked_MT5_fields;
    my @expected;
    my $params;
    my $mocked_MT5_object;
    $mocked_MT5->redefine("new"           => sub { return bless $mocked_MT5_fields, "BOM::Config::MT5" });
    $mocked_MT5->redefine("groups_config" => sub { return $mocked_groups_config });

    $mocked_MT5_fields = {};

    $mocked_groups_config = {
        'demo\p01_ts01\financial\labuan_stp_usd' => {
            "account_type"          => "demo",
            "landing_company_short" => "labuan",
            "market_type"           => "financial",
            "sub_account_type"      => "financial_stp",
            "server"                => "p01_ts01"
        }};
    @expected = ('demo\p01_ts01\financial\labuan_stp_usd');
    $params   = {
        "market_type" => "financial",
        "server_type" => "demo",
        "server_key"  => "p01_ts01",
        "company"     => "labuan",
        "sub_group"   => "stp"
    };
    $mocked_MT5_object = BOM::Config::MT5->new();
    my @got = $mocked_MT5_object->available_groups($params);
    is_deeply(\@got, \@expected, "Filtered upto sub_groups");

    $mocked_groups_config = {
        'demo\p01_ts01\financial\labuan_stp_usd' => {
            "account_type"          => "demo",
            "landing_company_short" => "labuan",
            "market_type"           => "financial",
            "sub_account_type"      => "financial_stp",
            "server"                => "p01_ts01"
        },
        'demo\p01_ts01\financial\bvi_stp_usd' => {
            "account_type"          => "demo",
            "landing_company_short" => "bvi",
            "market_type"           => "financial",
            "sub_account_type"      => "financial_stp",
            "server"                => "p01_ts01"
        }};
    @expected = ('demo\p01_ts01\financial\bvi_stp_usd', 'demo\p01_ts01\financial\labuan_stp_usd');
    $params   = {
        "server_type" => "demo",
        "server_key"  => "p01_ts01",
    };
    @got = $mocked_MT5_object->available_groups($params);
    is_deeply(\@got, \@expected, "Filtered upto server_key");
    $mocked_MT5->unmock_all();
};

subtest 'check mt5 account types structure' => sub {
    my $groups_configs = BOM::Config::mt5_account_types();

    foreach my $groups_config (keys %$groups_configs) {
        my $expected_keys = {
            account_type          => 1,
            landing_company_short => 1,
            market_type           => 1,
            sub_account_type      => 1,
            sub_account_category  => 1,
            server                => 1,
            landing_company_name  => 1,
        };

        my $actual_keys = {};
        $actual_keys->{$_} = 1 for keys %{$groups_configs->{$groups_config}};

        is_deeply($actual_keys, $expected_keys, 'group configuration contains expected keys');
    }
};

done_testing;
