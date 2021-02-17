#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Date::Utility;

my $qc = BOM::Config::QuantsConfig->new(
    chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    recorded_date    => Date::Utility->new
);

subtest 'save_config' => sub {
    clear_config();
    my $args = {
        currency_symbol => 'USD,JPY',
        name            => 'test',
        contract_type   => 'CALLE,PUT,ONETOUCH',
        start_time      => time,
        end_time        => time + 3600,
        ITM_1           => 1,
    };
    throws_ok { $qc->save_config('commission', +{%$args, contract_type => 'UNKNOWN,CALL'}) } qr/invalid input for contract_type \[UNKNOWN\]/,
        'throws if unknown contract type';
    throws_ok { $qc->save_config('commission', +{%$args, underlying_symbol => 'frxUSDJPY,CALL'}) } qr/invalid input for underlying_symbol \[CALL\]/,
        'throws if unknown underlying symbol';
    throws_ok { $qc->save_config('commission', +{%$args, ITM_1 => 'frxUSDJPY'}) } qr/invalid input for ITM_1/,
        'throws if unknown floor rate is invalid';
    throws_ok { $qc->save_config('xxxxx', $args) } qr/unregconized config type/, 'throws if unregconized config type';
    ok $qc->save_config('commission', $args), 'config saved';
    my $saved = $qc->chronicle_reader->get('quants_config', 'commission')->{test};
    is_deeply $saved->{contract_type},   [split ',', $args->{contract_type}],   'contract_type matches';
    is_deeply $saved->{currency_symbol}, [split ',', $args->{currency_symbol}], 'currency_symbol matches';
    is $saved->{ITM_1},                  $args->{ITM_1}, 'ITM_1 matches';
};

subtest 'delete_config' => sub {
    throws_ok { $qc->delete_config('commission', 'unknown') } qr/config does not exist/, 'throws error if config does not exist on delete';
    ok $qc->delete_config('commission', 'test'), 'config deleted';
};

subtest 'get_config without bias' => sub {
    clear_config();
    my $config = {
        currency_symbol   => 'USD',
        underlying_symbol => 'frxEURJPY,frxGBPJPY',
        cap_rate          => 0.1,
        name              => 'test',
        start_time        => time,
        end_time          => time + 3600,
    };
    ok $qc->save_config('commission', $config), 'config saved';
    my $configs = $qc->get_config(
        'commission',
        {
            underlying_symbol => 'frxEURUSD',
            contract_type     => 'CALLE'
        });
    ok @$configs == 1, 'matched one config';
    ok !@{
        $qc->get_config(
            'commission',
            {
                underlying_symbol => 'frxAUDJPY',
                contract_type     => 'CALLE'
            })
        },
        'no config';
    $configs = $qc->get_config(
        'commission',
        {
            underlying_symbol => 'frxEURJPY',
            contract_type     => 'CALLE'
        });
    ok @$configs == 1, 'matched one config';
};

subtest 'get_config with bias' => sub {
    clear_config();
    my $config = {
        currency_symbol   => 'USD',
        underlying_symbol => 'frxEURJPY,frxGBPJPY',
        cap_rate          => 0.1,
        name              => 'test',
        bias              => 'long',
        start_time        => time,
        end_time          => time + 3600,
    };
    ok $qc->save_config('commission', $config), 'config saved';
    note('Bias is set to long');
    my $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'CALLE',
            underlying_symbol => 'frxEURJPY'
        });
    ok @$configs == 1, 'one config for CALLE if config matches underlying symbol';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'PUT',
            underlying_symbol => 'frxEURJPY'
        });
    ok !@$configs, 'no config for PUT if config matches underlying symbol';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'CALL',
            underlying_symbol => 'frxUSDJPY'
        });
    ok @$configs == 1, 'one config for CALL if config matches the foreign currency';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'PUT',
            underlying_symbol => 'frxUSDJPY'
        });
    ok !@$configs, 'no config for PUT if config matches foreign currency';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'PUT',
            underlying_symbol => 'frxEURUSD'
        });
    ok @$configs == 1, 'one config for PUT if config matches domestic currency';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'cALLE',
            underlying_symbol => 'frxEURUSD'
        });
    ok !@$configs, 'no config for CALLE if config matches domestic currency';
    $configs = $qc->get_config(
        'commission',
        {
            contract_type     => 'CALL',
            underlying_symbol => 'WLDUSD'
        });
    ok !@$configs, 'no config for WLDUSD, no warnings as well';
};

# this test is time-dependant. So, try to eliminate false-negatives by adding one more second to 3600
subtest '_cleanup' => sub {
    clear_config();
    my $hour_before = time - 3601;
    my $args        = {
        underlying_symbol => 'frxUSDJPY',
        name              => 'test',
        start_time        => $hour_before,
        end_time          => $hour_before + 3599,
        partitions        => [{cap_rate => 0.3}],
    };
    $qc->save_config('commission', $args);
    my $configs = $qc->get_config(
        'commission',
        {
            underlying_symbol => 'frxUSDJPY',
            contract_type     => 'CAlle'
        });
    ok !@$configs, 'it did not get saved';
};

subtest 'multiplier_config' => sub {
    $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(Date::Utility->new),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new
    );

    ok $qc->get_multiplier_config('maltainvest', 'frxUSDJPY'), 'get_multiplier_config';
    ok $qc->get_multiplier_config(undef,         'R_100'),     'get_multiplier_config common';
    my $args = $qc->get_multiplier_config_default();
    ok $qc->save_config('multiplier_config::common::R_10', $args->{common}{R_10}), 'multiplier_config saved';
    ok !BOM::Config::Chronicle::clear_connections(), 'clear_connections';
};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', +{}, Date::Utility->new);
}

done_testing();
