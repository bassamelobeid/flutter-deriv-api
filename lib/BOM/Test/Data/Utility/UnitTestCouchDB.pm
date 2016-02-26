package BOM::Test::Data::Utility::UnitTestCouchDB;

=head1 NAME

BOM::Test::Data::Utility::UnitTestCouchDB

=head1 DESCRIPTION

To be used by an RMG unit test. 

=head1 SYNOPSIS

  use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

=cut

use 5.010;
use strict;
use warnings;

use BOM::MarketData::CorrelationMatrix;
use BOM::MarketData::EconomicEventCalendar;
use BOM::Platform::Runtime;
use Carp qw( croak );
use YAML::XS;

use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::VolSurface::Phased;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::System::Chronicle;
use BOM::System::RedisReplicated;
use Quant::Framework::Utils::Test;
use JSON;

sub initialize_symbol_dividend {
    my $symbol = shift;
    my $rate   = shift;

    my $document = {
        symbol          => $symbol,
        rates           => {'365' => $rate},
        discrete_points => undef
    };

    my $dv = BOM::MarketData::Dividend->new(symbol => $symbol);
    $dv->document($document);
    return $dv->save;
}

sub _init {
    #delete chronicle data too (Redis and Pg)
    BOM::System::RedisReplicated::redis_write()->flushall;
    BOM::System::Chronicle::_dbh()->do('delete from chronicle;') if BOM::System::Chronicle::_dbh();
    BOM::System::Chronicle::set(
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
                        'disabled'   => ['sectors'],
                        'disable_iv' => []
                    },
                    'features' => {
                        'suspend_claim_types' => [],
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
                            'global_scaling' => '100',
                        }}}
            },
            '_rev' => time
        });
    BOM::Platform::Runtime->instance(undef);

    initialize_symbol_dividend "R_25",    0;
    initialize_symbol_dividend "R_50",    0;
    initialize_symbol_dividend "R_75",    0;
    initialize_symbol_dividend "R_100",   0;
    initialize_symbol_dividend "RDBULL",  -35;
    initialize_symbol_dividend "RDBEAR",  20;
    initialize_symbol_dividend "RDSUN",   0;
    initialize_symbol_dividend "RDMOON",  0;
    initialize_symbol_dividend "RDMARS",  0;
    initialize_symbol_dividend "RDVENUS", 0;
    initialize_symbol_dividend "RDYANG",  -35;
    initialize_symbol_dividend "RDYIN",   20;

    BOM::System::Chronicle::set(
        'interest_rates',
        'JPY-USD',
        JSON::from_json(
            "{\"symbol\":\"JPY-USD\",\"rates\":{\"365\":\"2.339\",\"180\":\"2.498\",\"90\":\"2.599\",\"30\":\"2.599\",\"7\":\"2.686\"},\"date\":\"2016-01-26T17:00:03Z\",\"type\":\"market\"}"
        ));
    BOM::System::Chronicle::set('economic_events', 'economic_events', {events => []});

    return 1;
}

=head2 create doc()

    Create a new document in the test database

    params:
    $yaml_couch_db  => The name of the entity in the YAML file (eg. promo_code)
    $data_mod       => hasref of modifictions required to the data (optional)

=cut

sub create_doc {
    my ($yaml_couch_db, $data_mod) = @_;

    if (grep { $_ eq $yaml_couch_db } qw{currency}) {
        $data_mod->{chronicle_reader} = BOM::System::Chronicle::get_chronicle_reader();
        $data_mod->{chronicle_writer} = BOM::System::Chronicle::get_chronicle_writer();

        return Quant::Framework::Utils::Test::create_doc($yaml_couch_db, $data_mod);
    }

    my $save = 1;
    if (exists $data_mod->{save}) {
        $save = delete $data_mod->{save};
    }

    # get data to insert
    my $fixture = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/couch_unit_test.yml');
    my $data    = $fixture->{$yaml_couch_db}{data};

    die "Invalid yaml couch db name: $yaml_couch_db" if not defined $data;

    # modify data?
    for (keys %$data_mod) {
        $data->{$_} = $data_mod->{$_};
    }

    # use class to create the Couch doc
    my $class_name = $fixture->{$yaml_couch_db}{class_name};
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
