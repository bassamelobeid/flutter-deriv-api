#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::Deep qw( cmp_deeply );
use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::MarketData qw(create_underlying);
use Date::Utility;
use BOM::MarketData qw(create_underlying);

my $bet_params = {
    bet_type     => 'BINARYICO',
    underlying   => 'BTCICO',
    stake        => '0.0001',
    currency     => 'USD',
    duration     => '1400c',
    coin_address => '1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v'
};

subtest 'Ico variations' => sub {

    my $c = produce_contract($bet_params);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code,      'Binaryico',                                                       'is a Binaryico';
    is $c->ask_price, 0.0001,                                                            'correct ask price';
    is $c->payout,    0.0001,                                                            'correct payout';
    is $c->shortcode, 'BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'correct shortcode';
    is_deeply($c->longcode, ['Binary [_1] to be sent to [2]', 'ICO coloured coin', '1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v']);
    ok $c->is_valid_to_buy, 'is valid to buy';

    $bet_params->{underlying} = 'ERC20ICO';
    $c = produce_contract($bet_params);
    is $c->code,      'Binaryico',                                                         'is a Binaryico';
    is $c->ask_price, 0.0001,                                                              'correct ask price';
    is $c->payout,    0.0001,                                                              'correct payout';
    is $c->shortcode, 'BINARYICO_ERC20ICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'correct shortcode';
    is_deeply($c->longcode, ['Binary [_1] to be sent to [2]', 'ERC20 Ethereum token', '1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v']);
    ok $c->is_valid_to_buy, 'is valid to buy';

    $bet_params->{bet_type} = 'CALL';
    $c = produce_contract($bet_params);
    isnt $c, 'BOM::Product::Contract::Binaryico', 'is not a Binaryico';
    isnt $c->code, 'Binaryico', 'is not a binaryico';

    $bet_params->{bet_type}   = 'BINARYICO';
    $bet_params->{underlying} = 'frxUSDJPY';
    $c                        = produce_contract($bet_params);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code, 'Binaryico', 'is a Binaryico';
    ok !$c->is_valid_to_buy, 'is not valid to buy';
    is $c->primary_validation_error->message, 'Invalid token type. [symbol: frxUSDJPY]', 'Invalid token';

    $bet_params->{underlying} = 'BTCICO';
    $bet_params->{stake}      = '0.000';
    $c                        = produce_contract($bet_params);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code, 'Binaryico', 'is a Binaryico';
    ok !$c->is_valid_to_buy, 'is not valid to buy';
    is $c->primary_validation_error->message, 'The auction bid price can not be less than zero .', 'Zero bid price';

};

subtest 'shortcode_to_parameters' => sub {

    my $parameters = shortcode_to_parameters('BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'USD');
    my $BTCICO = create_underlying('BTCICO');

    my $expected = {
        underlying       => $BTCICO,
        shortcode        => 'BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400',
        bet_type         => 'BINARYICO',
        currency         => 'USD',
        prediction       => undef,
        amount_type      => 'stake',
        coin_address     => '1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v',
        amount           => '0.0001',
        date_start       => undef,
        date_expiry      => undef,
        fixed_expiry     => undef,
        tick_count       => undef,
        tick_expiry      => undef,
        is_sold          => undef,
        number_of_tokens => 1400
    };

    my $c = produce_contract($parameters);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code,      'Binaryico',                                                       'is a Binaryico';
    is $c->ask_price, 0.0001,                                                            'correct ask price';
    is $c->payout,    0.0001,                                                            'correct payout';
    is $c->shortcode, 'BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'correct shortcode';
    is_deeply($c->longcode, ['Binary [_1] to be sent to [2]', 'ICO coloured coin', '1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v']);
    ok $c->is_valid_to_buy, 'is valid to buy';

    cmp_deeply($parameters, $expected, 'BINARYICO shortcode.');
    my $legacy = shortcode_to_parameters('CALL_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    $legacy = shortcode_to_parameters('BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400_1493596800', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');
    }

