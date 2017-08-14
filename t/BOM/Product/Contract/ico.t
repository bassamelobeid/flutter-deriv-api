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
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();
my $now = Date::Utility->new;
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxEURUSD',
    epoch      => $now->epoch,
    quote      => 1.14
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDEUR',
    epoch      => $now->epoch,
    quote      => 1.14
});


my $bet_params = {
    bet_type     => 'BINARYICO',
    underlying   => 'BINARYICO',
    stake        => '1.0001',
    currency     => 'USD',
    duration     => '1400c',
};

subtest 'Ico variations' => sub {

    my $c = produce_contract($bet_params);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code,      'BINARYICO',                                                       'is a Binaryico';
    is $c->ask_price, 1400.14,                                                            'correct ask price';
    is $c->payout,    1400.14,                                                            'correct payout';
    is $c->shortcode, 'BINARYICO_1.0001_1400', 'correct shortcode';
    ok $c->is_valid_to_buy, 'is valid to buy';


    $bet_params->{bet_type} = 'CALL';
    $c = produce_contract({%$bet_params, date_expiry => Date::Utility->new});
    isnt $c, 'BOM::Product::Contract::Binaryico', 'is not a Binaryico';
    isnt $c->code, 'BINARYICO', 'is not a binaryico';

    $bet_params->{bet_type} = 'BINARYICO';
    $bet_params->{underlying} = 'BINARYICO';
    $bet_params->{stake}      = '0.0001';
    $bet_params->{currency} = 'EUR';
    $c                        = produce_contract($bet_params);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code, 'BINARYICO', 'is a Binaryico';
    ok !$c->is_valid_to_buy, 'is not valid to buy';
    is $c->primary_validation_error->message, 'The minimum bid is USD 1 or equivalent in other currency.', 'Minimum bid of USD1';

};

subtest 'shortcode_to_parameters' => sub {

    my $parameters = shortcode_to_parameters('BINARYICO_1.0001_1400', 'USD');
    my $expected = {
        underlying       => create_underlying('BINARYICO'),
        shortcode        => 'BINARYICO_1.0001_1400',
        bet_type         => 'BINARYICO',
        currency         => 'USD',
        prediction       => undef,
        amount_type      => 'stake',
        amount           => '1.0001',
        binaryico_per_token_bid_price => '1.0001',
        date_start       => undef,
        date_expiry      => undef,
        fixed_expiry     => undef,
        tick_count       => undef,
        tick_expiry      => undef,
        is_sold          => undef,
        binaryico_number_of_tokens => 1400
    };

    my $c = produce_contract($parameters);
    isa_ok $c, 'BOM::Product::Contract::Binaryico', 'is a Binaryico';
    is $c->code,      'BINARYICO',                                                       'is a Binaryico';
    is $c->ask_price, 1400.14,                                                            'correct ask price';
    is $c->payout,    1400.14,                                                            'correct payout';
    is $c->shortcode, 'BINARYICO_1.0001_1400', 'correct shortcode';
    ok $c->is_valid_to_buy, 'is valid to buy';

    cmp_deeply($parameters, $expected, 'BINARYICO shortcode.');
    my $legacy = shortcode_to_parameters('CALL_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    $legacy = shortcode_to_parameters('BINARYICO_BTCICO_1HB5XMLmzFVj8ALj6mfBsbifRoD4miY36v_0.0001_1400_1493596800', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');
    }

