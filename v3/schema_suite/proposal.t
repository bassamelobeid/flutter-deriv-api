use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;
use BOM::Test::Data::Utility::FeedTestDatabase;

start(
    title             => "proposal.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

# Reconnect in English
set_language 'EN';

# need to mock these for volsurface
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            28  => 2.2099,
            273 => 3.1169,
            1   => 1.9083,
            60  => 2.2973,
            89  => 2.5674,
            365 => 3.1466,
            7   => 1.9396,
            14  => 2.1367,
            181 => 2.9215
        },
        symbol        => 'EUR-USD',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            7   => -0.3685,
            14  => 0.3301,
            181 => -0.1820,
            365 => -0.2036,
            1   => -3.2936,
            273 => -0.1440,
            60  => -0.3821,
            28  => -0.3239,
            89  => -0.2370
        },
        symbol        => 'JPY-USD',
    });

# need to mock these for MULT contracts
for my $epoch (1470744064, 1470744072, 1470744088) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 65258.19
    });
}

# UNAUTHENTICATED TESTS
# contract prices are very sensitive to time. Please avoid having anything before these test.
# invalid duration
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_offerings_validation_error.json', '100', 'ASIANU', 'R_100', '5', 'm';
# invalid contract type
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_input_validation_error.json', '100', 'INVALID', 'R_100', '5', 'm';
# invalid contract duration
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_buy_duration_exception.json', '100', 'ASIANU', 'R_100', '0', 't';
# invalid underlying symbol
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_buy_exception.json', '100', 'ASIANU', 'INVALID', '5', 't';

# R_100
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'ASIANU', 'R_100', '5', 't', 'Win payout if the last tick of Volatility 100 Index is strictly higher than the average of the 5 ticks.',
    '51.19', '51.19', '65258.19';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'R_100', '30', 'd', 'Win payout if Volatility 100 Index is strictly higher than entry spot at close on 2016-09-08.', '45.44',
    '45.44', '65258.19';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'R_100', '15', 's',
    'Win payout if Volatility 100 Index is strictly higher than entry spot at 15 seconds after contract start time.', '51.19', '51.19', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'DIGITMATCH', 'R_100', '10', 't', '0', 'Win payout if the last digit of Volatility 100 Index is 0 after 10 ticks.', 11.00, '11.00', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'R_100', '15', 'm', '+0.1',
    'Win payout if Volatility 100 Index is strictly higher than entry spot plus 0.10 at 15 minutes after contract start time.', '51.08', '51.08',
    '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'R_100', '30', 'd', '65268.19', 'Win payout if Volatility 100 Index is strictly higher than 65268.19 at close on 2016-09-08.', '45.41',
    '45.41', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '2', 'm', '+200',
    'Win payout if Volatility 100 Index touches entry spot plus 200.00 through 2 minutes after contract start time.', '10.92', '10.92', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '30', 'd', '69968.19', 'Win payout if Volatility 100 Index touches 69968.19 through close on 2016-09-08.', '79.19', '79.19',
    '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'R_100', '2', 'm', '+10', '-5',
    'Win payout if Volatility 100 Index ends outside entry spot minus 5.00 to entry spot plus 10.00 at 2 minutes after contract start time.',
    '96.46', '96.46', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYRANGE', 'R_100', '30', 'd', '65968.19', '65068.19',
    'Win payout if Volatility 100 Index ends strictly between 65068.19 to 65968.19 at close on 2016-09-08.', '3.07', '3.07', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'R_100', '30', 'd', '65271.19', '65257.19',
    'Win payout if Volatility 100 Index stays between 65257.19 to 65271.19 through close on 2016-09-08.', 2.50, '2.50', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'UPORDOWN', 'R_100', '2', 'm', '+200', '-50',
    'Win payout if Volatility 100 Index goes outside entry spot minus 50.00 and entry spot plus 200.00 through 2 minutes after contract start time.',
    '73.69', '73.69', '65258.19';

# frxUSDJPY
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '15', 'm', 'Win payout if USD/JPY is strictly higher than entry spot at 15 minutes after contract start time.',
    57.49, '57.49', 97.140;
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '30', 'm', 'Win payout if USD/JPY is strictly higher than entry spot at 30 minutes after contract start time.',
    57.49, '57.49', 97.140;
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '1', 'h', 'Win payout if USD/JPY is strictly higher than entry spot at 1 hour after contract start time.', '57.48',
    '57.48', '97.140';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '1', 'd', 'Win payout if USD/JPY is strictly higher than entry spot at close on 2016-08-10.', '55.74', '55.74',
    97.140;
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_validation_error.json',
    'CALL', 'frxUSDJPY', '15', 'm', '+0.01',
    'Win payout if USD/JPY is strictly higher than entry spot plus  10 pips at 15 minutes after contract start time.', '47.54', '47.54', '97.140';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_validation_error.json',
    'CALL', 'frxUSDJPY', '30', 'm', '+0.01',
    'Win payout if USD/JPY is strictly higher than entry spot plus  10 pips at 30 minutes after contract start time.', '48.99', '48.99', '97.140';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_validation_error.json',
    'CALL', 'frxUSDJPY', '1', 'h', '+0.01',
    'Win payout if USD/JPY is strictly higher than entry spot plus  10 pips at 1 hour after contract start time.', '49.91', '49.91', '97.140';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_validation_error.json',
    'CALL', 'frxUSDJPY', '2', 'h', '+0.01',
    'Win payout if USD/JPY is strictly higher than entry spot plus  10 pips at 2 hours after contract start time.', '50.88', '50.88', '97.140';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'frxUSDJPY', '1', 'd', '97.150', 'Win payout if USD/JPY is strictly higher than 97.150 at close on 2016-08-10.', '55.00', '55.00',
    97.140;
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'frxUSDJPY', '1', 'd', '97.270', 'Win payout if USD/JPY touches 97.270 through close on 2016-08-10.', '86.41', '86.41', 97.140;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'frxUSDJPY', '1', 'd', '97.250', '97.100', 'Win payout if USD/JPY ends outside 97.100 to 97.250 at close on 2016-08-10.', '91.78',
    '91.78', 97.140;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'frxUSDJPY', '1', 'd', '98.350', '96.830', 'Win payout if USD/JPY stays between 96.830 to 98.350 through close on 2016-08-10.', '46.78',
    '46.78', 97.140;

# OTC_FCHI
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'OTC_FCHI', '15', 'm', 'Win payout if France 40 is strictly higher than entry spot at 15 minutes after contract start time.',
    '54.99', '54.99', '3563.07';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'OTC_FCHI', '1', 'd', 'Win payout if France 40 is strictly higher than entry spot at close on 2016-08-10.', '52.89', '52.89',
    '3563.07';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'OTC_FCHI', '7', 'd', '3564', 'Win payout if France 40 is strictly higher than 3564.00 at close on 2016-08-16.', '51.14', '51.14',
    '3563.07';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'OTC_FCHI', '7', 'd', '3624', 'Win payout if France 40 touches 3624.00 through close on 2016-08-16.', '41.06', '41.06', '3563.07';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'OTC_FCHI', '7', 'd', '3600', '3490', 'Win payout if France 40 ends outside 3490.00 to 3600.00 at close on 2016-08-16.', '45.32',
    '45.32', '3563.07';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'OTC_FCHI', '7', 'd', '3600', '3490', 'Win payout if France 40 stays between 3490.00 to 3600.00 through close on 2016-08-16.',
    '38.76',
    '38.76', '3563.07';

# frxXAUUSD
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxXAUUSD', '15', 'm', 'Win payout if Gold/USD is strictly higher than entry spot at 15 minutes after contract start time.',
    '56.49', '56.49', '111.00';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxXAUUSD', '1', 'd', 'Win payout if Gold/USD is strictly higher than entry spot at close on 2016-08-10.', '54.23', '54.23',
    111.00;
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'frxXAUUSD', '7', 'd', '112', 'Win payout if Gold/USD touches 112.00 through close on 2016-08-16.', '76.40', '76.40', 111.00;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'frxXAUUSD', '7', 'd', '113', '108', 'Win payout if Gold/USD ends outside 108.00 to 113.00 at close on 2016-08-16.', '41.723',
    '41.73', 111.00;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'frxXAUUSD', '7', 'd', '113', '108', 'Win payout if Gold/USD stays between 108.00 to 113.00 through close on 2016-08-16.', 56.27,
    '56.27', 111.00;

# frxUSDJPY 7 day CALL
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '7', 'd', 'Win payout if USD/JPY is strictly higher than entry spot at close on 2016-08-16.', '56.87', '56.87',
    97.14;

# R_100 Lookbacks
test_sendrecv_params 'proposal/test_send_lookback.json', 'proposal/test_receive_lookback.json',
    'LBFLOATCALL', 'R_100', '15', 'm', '', 'Win USD 10.0 times Volatility 100 Index\'s close minus low over the next 15 minutes.', '2750.00',
    '2750.00', 65258.19;

# R_100 touch tick trade
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '5', 't', '+20.5',
    'Win payout if Volatility 100 Index touches entry spot plus 20.50 through 5 ticks after first tick.', '44.51', '44.51', '65258.19';

# test for negative amount
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive_negative.json', '-1', 'ASIANU', 'R_100', '5', 't';

# callput spread
test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'CALLSPREAD', 'frxUSDJPY', '15', 'd', 'tight';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'CALLSPREAD', 'R_100', '15', 'd', 'middle';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'CALLSPREAD', 'frxUSDJPY', '15', 'd', 'wide';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'PUTSPREAD', 'frxUSDJPY', '15', 'd', 'tight';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'PUTSPREAD', 'R_100', '15', 'd', 'middle';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'PUTSPREAD', 'frxUSDJPY', '15', 'd', 'wide';

# multiplier
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'payout', '10',
    'ContractCreationFailure', 'Basis must be stake for this contract.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'frxGBPPLN', 'stake', '10',
    'OfferingsValidationError', 'Trading is not offered for this asset.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'stake', '5',
    'ContractBuyValidationError', 'Multiplier is not in acceptable range. Accepts 10,20,30,50,100.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_multiplier.json', 'MULTUP', 'R_100', 'stake', '10',
    'Win 10% of your stake for every 1% rise in Volatility 100 Index.', '100.00', '100', '65258.19', 'Stop out', '58765.24', '', '';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'something', '1', 'InputValidationFailed', 'Input validation failed: limit_order';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'take_profit', '0', 'ContractBuyValidationError', 'Please enter a take profit amount that\'s higher than 0.10.';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'stop_loss', '-1', 'ContractBuyValidationError', "Please enter a stop loss amount that\'s higher than 0.10.";
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_multiplier_limit_order.json', 'MULTUP', 'R_100',
    'stake',     '10',
    'stop_loss', '1', 'Win 10% of your stake for every 1% rise in Volatility 100 Index.', '100.00', '100', '65258.19', 'Stop out', '58765.24',
    'Stop loss', '65225.80';

# multiplier
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'payout', '10',
    'ContractCreationFailure', 'Basis must be stake for this contract.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'frxGBPPLN', 'stake', '10',
    'OfferingsValidationError', 'Trading is not offered for this asset.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'stake', '5',
    'ContractBuyValidationError', 'Multiplier is not in acceptable range. Accepts 10,20,30,50,100.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_multiplier.json', 'MULTUP', 'R_100', 'stake', '10',
    'Win 10% of your stake for every 1% rise in Volatility 100 Index.', '100.00', '100', '65258.19', 'Stop out', '58765.24', '', '';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'something', '1', 'InputValidationFailed', 'Input validation failed: limit_order';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'take_profit', '-1', 'ContractBuyValidationError', 'Please enter a take profit amount that\'s higher than 0.10.';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake',
    '10',
    'stop_loss', '0.1', 'ContractBuyValidationError', "Invalid stop loss. Stop loss must be higher than commission";
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_multiplier_limit_order.json', 'MULTUP', 'R_100',
    'stake',     '10',
    'stop_loss', '1', 'Win 10% of your stake for every 1% rise in Volatility 100 Index.', '100.00', '100', '65258.19', 'Stop out', '58765.24',
    'Stop loss', '65225.80';

#subscription
test_sendrecv_params 'proposal/test_send_subscribe.json', 'proposal/test_receive_subscribe.json',
    '100', 'ASIANU', 'R_100', '5', 't', 'Win payout if the last tick of Volatility 100 Index is strictly higher than the average of the 5 ticks.',
    '51.19', '51.19', '65258.19';

finish;
