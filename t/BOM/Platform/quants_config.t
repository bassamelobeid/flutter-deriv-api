#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use Date::Utility;

my $qc = BOM::Platform::QuantsConfig->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
    recorded_date    => Date::Utility->new
);

# clears data
$qc->chronicle_writer->set('quants_config', 'commission', +{}, Date::Utility->new);

subtest 'save_config' => sub {
    my $args = {
        currency_symbol => 'USD,JPY',
        name            => 'test',
        contract_type   => 'CALLE,PUT,ONETOUCH',
        partitions      => [{cap_rate => 0.3}],
    };
    ok $qc->save_config('commission', $args), 'config saved';
    my $saved = $qc->chronicle_reader->get('quants_config', 'commission')->{test};
    is_deeply $saved->{contract_type},   [split ',', $args->{contract_type}],   'contract_type matches';
    is_deeply $saved->{currency_symbol}, [split ',', $args->{currency_symbol}], 'currency_symbol matches';
    is_deeply $saved->{partitions}, $args->{partitions}, 'partitions matches';
    throws_ok { $qc->save_config('commission', +{%$args, contract_type => 'UNKNOWN,CALL'}) } qr/invalid input for contract_type \[UNKNOWN\]/,
        'throws if unknown contract type';
    throws_ok { $qc->save_config('commission', +{%$args, underlying_symbol => 'frxUSDJPY,CALL'}) } qr/invalid input for underlying_symbol \[CALL\]/,
        'throws if unknown underlying symbol';
    throws_ok { $qc->save_config('commission', +{%$args, partitions => [{floor_rate => 'frxUSDJPY'}]}) } qr/invalid input for floor_rate/,
        'throws if unknown floor rate is invalid';
};

subtest 'delete_config' => sub {
    throws_ok { $qc->delete_config('commission', 'unknown') } qr/config does not exist/, 'throws error if config does not exist on delete';
    ok $qc->delete_config('commission', 'test'), 'config deleted';
};

subtest 'get_config' => sub {
    my $config = {
        currency_symbol   => 'USD',
        underlying_symbol => 'frxEURJPY,frxGBPJPY',
        cap_rate          => 0.1,
        name              => 'test'
    };
    ok $qc->save_config('commission', $config), 'config saved';
    my $configs = $qc->get_config(
        'commission',
        {
            underlying_symbol => 'frxEURUSD',
            contract_type     => 'CALLE'
        });
    ok @$configs == 1, 'matched one config';
    ok $configs->[0]->{reverse_delta}, 'parses reverse_delta flag';
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
    ok !$configs->[0]->{reverse_delta}, 'no reverse_delta flag';

    $configs = $qc->get_config(
        'commission',
        {
            underlying_symbol => 'frxUSDJPY',
            contract_type     => 'CALLE'
        });
    ok @$configs == 1, 'matched one config';
    ok !$configs->[0]->{reverse_delta}, 'no reverse_delta flag';

    my $new_config = {
        contract_type => 'CALLE',
        name          => 'test_ct',
        cap_rate      => 0.5
    };
    ok $qc->save_config('commission', $new_config), 'new config saved';
    ok @{
        $qc->get_config(
            'commission',
            {
                underlying_symbol => 'frxEURJPY',
                contract_type     => 'CALLE'
            })} == 2, 'two config';
    ok @{
        $qc->get_config(
            'commission',
            {
                underlying_symbol => 'frxEURJPY',
                contract_type     => 'ONETOUCH'
            })} == 1, 'one config';
    ok @{
        $qc->get_config(
            'commission',
            {
                underlying_symbol => 'frxAUDJPY',
                contract_type     => 'CALLE'
            })} == 1, 'one config';

};

done_testing();
