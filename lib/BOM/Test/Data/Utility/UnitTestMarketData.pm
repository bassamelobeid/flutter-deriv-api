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

use JSON::MaybeXS;
use Carp qw( croak );
use YAML::XS;
use List::Util qw(uniq);

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Chronicle;
use BOM::Config::RedisReplicated;
use BOM::Test;

use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use Quant::Framework::CorrelationMatrix;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::Utils::Test;
use Quant::Framework::Asset;

use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods generate_barriers_for_window update_predefined_highlow);
use BOM::Product::ContractFinder;
use BOM::CompanyLimits::Groups;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub _initialize_symbol_dividend {
    my $symbol = shift;
    my $rate   = shift;

    my $document = {
        symbol => $symbol,
        rates  => {'365' => $rate},
    };

    my $dv = Quant::Framework::Asset->new(
        symbol           => $symbol,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );

    $dv->document($document);
    return $dv->save;
}

sub _init {
    my $writer = BOM::Config::Chronicle::get_chronicle_writer();
    #delete chronicle data too (Redis and Pg)
    $writer->cache_writer->flushall;

    # Set default limit groups in Redis only. In production both userdb and redis is populated,
    # but it suffice to pass most tests to just have the Redis instance populated. This also
    # reduces intermitent database connection failures for whatever reason I could not figure out.
    $writer->cache_writer->hmset('contractgroups',   BOM::CompanyLimits::Groups::get_default_contract_group_mappings());
    $writer->cache_writer->hmset('underlyinggroups', BOM::CompanyLimits::Groups::get_default_underlying_group_mappings());

    BOM::Config::Chronicle::dbic()->run(fixup => sub { $_->do('delete from chronicle;') }) if BOM::Config::Chronicle::dbic();
    $writer->set(
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
                    'markets' => {
                        'disabled' => ['sectors'],
                    },
                    'features' => {
                        'suspend_contract_types' => [],
                    },
                    'client_limits' => {
                        'asian_turnover_limit' => '50000',
                        'intraday_forex_iv'    => '{
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
                                'volidx'      => '100',
                                'config'      => '100',
                            }}
                    },
                    enable_global_potential_loss => 0,
                    enable_global_realized_loss  => 0,
                },
            },
            '_rev' => time
        },
        Date::Utility->new
    );
    # BOM::Config::Runtime->instance(undef);

    _initialize_symbol_dividend "R_25",   0;
    _initialize_symbol_dividend "R_50",   0;
    _initialize_symbol_dividend "R_75",   0;
    _initialize_symbol_dividend "R_100",  0;
    _initialize_symbol_dividend "RDBULL", -35;
    _initialize_symbol_dividend "RDBEAR", 20;

    $writer->set(
        'interest_rates',
        'JPY-USD',
        JSON::MaybeXS->new->decode(
            "{\"symbol\":\"JPY-USD\",\"rates\":{\"365\":\"2.339\",\"180\":\"2.498\",\"90\":\"2.599\",\"30\":\"2.599\",\"7\":\"2.686\"},\"date\":\"2016-01-26T17:00:03Z\",\"type\":\"market\"}"
        ),
        Date::Utility->new
    );
    # set a recorded date that is incredibly back in time due to tests usually have different static times.
    $writer->set('economic_events', 'economic_events', {events => []}, Date::Utility->new('2000-01-01'));

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
        qw{currency randomindex index holiday economic_events partial_trading asset correlation_matrix volsurface_moneyness volsurface_delta})
    {
        $data_mod->{chronicle_reader} = BOM::Config::Chronicle::get_chronicle_reader();
        $data_mod->{chronicle_writer} = BOM::Config::Chronicle::get_chronicle_writer();

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

sub create_predefined_parameters_for {
    my ($symbol, $date) = @_;

    my $tp = create_trading_periods($symbol, $date);
    my @start_times = sort { $a <=> $b } uniq map { $_->{date_start}->{epoch} } @$tp;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $_,
            quote      => 100,
        }) for (@start_times);
    create_predefined_barriers($symbol, $_, $date) for (@$tp);
    update_predefined_highlow({
        symbol => $symbol,
        epoch  => $date->epoch,
        quote  => 100
    });
    my $barrier_by_category = create_predefined_barriers_by_contract_category($symbol, $date);

    return ($tp, $barrier_by_category);
}

sub create_predefined_barriers_by_contract_category {
    my ($symbol, $date) = @_;

    my $data = BOM::Product::ContractFinder->new(for_date => $date)->multi_barrier_contracts_by_category_for({symbol => $symbol});
    my @redis_key = BOM::Product::Contract::PredefinedParameters::barrier_by_category_key($symbol);
    BOM::Config::Chronicle::get_chronicle_writer()->set(@redis_key, $data, $date, 1, 300);    # cached for 5 minutes

    return $data;
}

sub create_trading_periods {
    my ($symbol, $date) = @_;

    my $periods = BOM::Product::Contract::PredefinedParameters::generate_trading_periods($symbol, $date);
    my @redis_key = BOM::Product::Contract::PredefinedParameters::trading_period_key($symbol, $date);

    # 1 - to save to chronicle database
    # ttl - set to 5 minutes
    BOM::Config::Chronicle::get_chronicle_writer()->set(@redis_key, [grep { defined } @$periods], $date, 1, 300);

    return $periods;
}

sub create_predefined_barriers {
    my ($symbol, $trading_window, $date) = @_;

    $date //= Date::Utility->new;
    my $barriers = BOM::Product::Contract::PredefinedParameters::generate_barriers_for_window($symbol, $trading_window);
    return unless $barriers;
    my @redis_key = BOM::Product::Contract::PredefinedParameters::predefined_barriers_key($symbol, $trading_window);

    # 1 - to save to chronicle database
    # ttl - set to 5 minutes
    BOM::Config::Chronicle::get_chronicle_writer()->set(@redis_key, $barriers, $date, 1, 300);

    return $barriers;
}

sub import {
    my (undef, $init) = @_;
    _init() if $init && $init eq ':init';
    return;
}

1;
