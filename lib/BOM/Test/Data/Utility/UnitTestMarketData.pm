package BOM::Test::Data::Utility::UnitTestMarketData;

=head1 NAME

BOM::Test::Data::Utility::UnitTestMarketData

=head1 DESCRIPTION

To be used by an RMG unit test.

=head1 SYNOPSIS

  use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

=cut

use 5.010;
use strict;
use warnings;

use JSON;
use Carp qw( croak );
use YAML::XS;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Chronicle;
use BOM::Platform::RedisReplicated;
use BOM::Test;

use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use Quant::Framework::CorrelationMatrix;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::Utils::Test;
use Quant::Framework::Asset;

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub _initialize_symbol_dividend {
    my $symbol = shift;
    my $rate   = shift;

    my $document = {
        symbol          => $symbol,
        rates           => {'365' => $rate},
        discrete_points => undef
    };

    my $dv = Quant::Framework::Asset->new(
        symbol           => $symbol,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );

    $dv->document($document);
    return $dv->save;
}

sub _init {
    #delete chronicle data too (Redis and Pg)
    BOM::Platform::RedisReplicated::redis_write()->flushall;
    BOM::Platform::Chronicle::_dbh()->do('delete from chronicle;') if BOM::Platform::Chronicle::_dbh();
    BOM::Platform::Chronicle::set(
        'app_settings',
        'binary',
        {
            'global' => {
                'payments'  => {},
                'marketing' => {},
                'system'    => {
                    'suspend' => {
                        'new_accounts'   => 0,
                        'payments'       => 0,
                        'payment_agents' => 0,
                        'system'         => '0',
                        'trading'        => '0',
                        'all_logins'     => '0',
                        'logins'         => []}
                },
                'cgi' => {
                    'allowed_languages' => ['EN', 'ID', 'RU', 'ZH_CN'],
                    'backoffice'               => {'static_url' => 'https://regentmarkets.github.io/binary-static-backoffice/'},
                    'terms_conditions_version' => 'Version 39 2015-12-04'
                },
                'quants' => {
                    'underlyings' => {'disabled_due_to_corporate_actions' => []},
                    'markets'     => {
                        'disabled' => ['sectors'],
                    },
                    'features' => {
                        'suspend_contract_types' => [],
                    },
                    'client_limits' => {
                        'asian_turnover_limit'       => '50000',
                        'spreads_daily_profit_limit' => '10000',
                        'intraday_forex_iv'          => '{
                               "potential_profit" : 35000,
                               "realized_profit" : 35000,
                               "turnover" : 35000
                            }',
                        'tick_expiry_engine_turnover_limit' => '0.5'
                    },
                    'commission' => {
                        'adjustment' => {
                            'per_market_scaling' => {
                                'forex'       => '100',
                                'indices'     => '100',
                                'commodities' => '100',
                                'stocks'      => '100',
                                'volidx'      => '100',
                                'config'      => '100',
                            }}}}
            },
            '_rev' => time
        });
    # BOM::Platform::Runtime->instance(undef);

    _initialize_symbol_dividend "R_25",   0;
    _initialize_symbol_dividend "R_50",   0;
    _initialize_symbol_dividend "R_75",   0;
    _initialize_symbol_dividend "R_100",  0;
    _initialize_symbol_dividend "RDBULL", -35;
    _initialize_symbol_dividend "RDBEAR", 20;

    BOM::Platform::Chronicle::set(
        'interest_rates',
        'JPY-USD',
        JSON::from_json(
            "{\"symbol\":\"JPY-USD\",\"rates\":{\"365\":\"2.339\",\"180\":\"2.498\",\"90\":\"2.599\",\"30\":\"2.599\",\"7\":\"2.686\"},\"date\":\"2016-01-26T17:00:03Z\",\"type\":\"market\"}"
        ));
    BOM::Platform::Chronicle::set('economic_events', 'economic_events', {events => []});

    return 1;
}

=head2 create doc()

    Create a new document in the test database

    params:
    $yaml_db  => The name of the entity in the YAML file (eg. promo_code)
    $data_mod       => hasref of modifictions required to the data (optional)

=cut

sub create_doc {
    my ($yaml_db, $data_mod) = @_;

    if (grep { $_ eq $yaml_db }
        qw{currency randomindex stock index holiday economic_events partial_trading asset correlation_matrix volsurface_moneyness volsurface_delta})
    {
        $data_mod->{chronicle_reader} = BOM::Platform::Chronicle::get_chronicle_reader();
        $data_mod->{chronicle_writer} = BOM::Platform::Chronicle::get_chronicle_writer();

        if ($yaml_db eq 'volsurface_delta' or $yaml_db eq 'volsurface_moneyness') {
            if (exists($data_mod->{symbol}) and not exists($data_mod->{underlying})) {
                $data_mod->{underlying} = create_underlying($data_mod->{symbol});
                delete $data_mod->{symbol};
            }
        }

        return Quant::Framework::Utils::Test::create_doc($yaml_db, $data_mod);
    }

    my $save = 1;
    if (exists $data_mod->{save}) {
        $save = delete $data_mod->{save};
    }

    # get data to insert
    my $fixture = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/market_unit_test.yml');
    my $data    = $fixture->{$yaml_db}{data};

    die "Invalid yaml db name: $yaml_db" if not defined $data;

    # modify data?
    for (keys %$data_mod) {
        $data->{$_} = $data_mod->{$_};
    }

    # use class to create the doc
    my $class_name = $fixture->{$yaml_db}{class_name};
    my $obj        = $class_name->new($data);

    if ($save) {
        $obj->save;
    }

    return $obj;
}

sub import {
    my ($class, $init) = @_;
    _init() if $init && $init eq ':init';
    return;
}

1;
