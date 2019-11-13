use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

start(
    title             => "proposal.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

# Reconnect in English
set_language 'EN';

# UNAUTHENTICATED TESTS

# contract prices are very sensitive to time. Please avoid having anything before these test.
# invalid duration
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_offerings_validation_error.json', '100', 'ASIANU', 'R_100', '5', 'm';
# invalid contract type
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_input_validation_error.json', '100', 'INVALID', 'R_100', '5', 'm';
# invalid contract duration
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_buy_exception.json', '100', 'ASIANU', 'R_100', '0', 't';
# invalid underlying symbol
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_buy_exception.json', '100', 'ASIANU', 'INVALID', '5', 't';

# R_100
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'ASIANU', 'R_100', '5', 't', 'Win payout if the last tick of Volatility 100 Index is strictly higher than the average of the 5 ticks.',
    '51.49', '51.49', '65258.19';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'R_100', '30', 'd', 'Win payout if Volatility 100 Index is strictly higher than entry spot at close on 2016-09-08.', '45.74',
    '45.74', '65258.19';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'R_100', '15', 's',
    'Win payout if Volatility 100 Index is strictly higher than entry spot at 15 seconds after contract start time.', '51.49', '51.49', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'DIGITMATCH', 'R_100', '10', 't', '0', 'Win payout if the last digit of Volatility 100 Index is 0 after 10 ticks.', 11.00, '11.00', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'R_100', '15', 'm', '+0.1',
    'Win payout if Volatility 100 Index is strictly higher than entry spot plus 0.10 at 15 minutes after contract start time.', '51.38', '51.38',
    '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'R_100', '30', 'd', '65268.19', 'Win payout if Volatility 100 Index is strictly higher than 65268.19 at close on 2016-09-08.', '45.71',
    '45.71', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '2', 'm', '+200',
    'Win payout if Volatility 100 Index touches entry spot plus 200.00 through 2 minutes after contract start time.', '11.22', '11.22', '65258.19';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '30', 'd', '69968.19', 'Win payout if Volatility 100 Index touches 69968.19 through close on 2016-09-08.', '79.49', '79.49',
    '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'R_100', '2', 'm', '+10', '-5',
    'Win payout if Volatility 100 Index ends outside entry spot minus 5.00 to entry spot plus 10.00 at 2 minutes after contract start time.',
    '96.76', '96.76', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYRANGE', 'R_100', '30', 'd', '65968.19', '65068.19',
    'Win payout if Volatility 100 Index ends strictly between 65068.19 to 65968.19 at close on 2016-09-08.', '3.37', '3.37', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'R_100', '30', 'd', '65271.19', '65257.19',
    'Win payout if Volatility 100 Index stays between 65257.19 to 65271.19 through close on 2016-09-08.', 2.50, '2.50', '65258.19';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'UPORDOWN', 'R_100', '2', 'm', '+200', '-50',
    'Win payout if Volatility 100 Index goes outside entry spot minus 50.00 and entry spot plus 200.00 through 2 minutes after contract start time.',
    '73.99', '73.99', '65258.19';

# frxUSDJPY
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '5', 't', 'Win payout if USD/JPY after 5 ticks is strictly higher than entry spot.', '49.60', '49.60', 97.140;
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '3', 'm', 'Win payout if USD/JPY is strictly higher than entry spot at 3 minutes after contract start time.',
    57, '57.00', 97.140;
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '1', 'h', 'Win payout if USD/JPY is strictly higher than entry spot at 1 hour after contract start time.', '56.99',
    '56.99', '97.140';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '1', 'd', 'Win payout if USD/JPY is strictly higher than entry spot at close on 2016-08-10.', '56.62', '56.62',
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
    'CALL', 'frxUSDJPY', '1', 'd', '97.150', 'Win payout if USD/JPY is strictly higher than 97.150 at close on 2016-08-10.', '55.84', '55.84',
    97.140;
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'frxUSDJPY', '1', 'd', '97.270', 'Win payout if USD/JPY touches 97.270 through close on 2016-08-10.', '86.98', '86.98', 97.140;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'frxUSDJPY', '1', 'd', '97.250', '97.100', 'Win payout if USD/JPY ends outside 97.100 to 97.250 at close on 2016-08-10.', '91.99',
    '91.99', 97.140;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'frxUSDJPY', '1', 'd', '98.350', '96.830', 'Win payout if USD/JPY stays between 96.830 to 98.350 through close on 2016-08-10.', '46.67',
    '46.67', 97.140;

# FCHI
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'FCHI', '15', 'm', 'Win payout if French Index is strictly higher than entry spot at 15 minutes after contract start time.',
    '54.99', '54.99', '3563.07';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'FCHI', '1', 'd', 'Win payout if French Index is strictly higher than entry spot at close on 2016-08-10.', '52.92', '52.92',
    '3563.07';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'CALL', 'FCHI', '7', 'd', '3564', 'Win payout if French Index is strictly higher than 3564.00 at close on 2016-08-16.', '51.12', '51.12',
    '3563.07';
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'FCHI', '7', 'd', '3624', 'Win payout if French Index touches 3624.00 through close on 2016-08-16.', '40.89', '40.89', '3563.07';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'FCHI', '7', 'd', '3600', '3490', 'Win payout if French Index ends outside 3490.00 to 3600.00 at close on 2016-08-16.', '45.24',
    '45.24', '3563.07';
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'FCHI', '7', 'd', '3600', '3490', 'Win payout if French Index stays between 3490.00 to 3600.00 through close on 2016-08-16.', '37.48',
    '37.48', '3563.07';

# frxXAUUSD
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxXAUUSD', '15', 'm', 'Win payout if Gold/USD is strictly higher than entry spot at 15 minutes after contract start time.',
    '56.49', '56.49', '111.00';
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxXAUUSD', '1', 'd', 'Win payout if Gold/USD is strictly higher than entry spot at close on 2016-08-10.', '54.22', '54.22',
    111.00;
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'frxXAUUSD', '7', 'd', '112', 'Win payout if Gold/USD touches 112.00 through close on 2016-08-16.', '76.42', '76.42', 111.00;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'EXPIRYMISS', 'frxXAUUSD', '7', 'd', '113', '108', 'Win payout if Gold/USD ends outside 108.00 to 113.00 at close on 2016-08-16.', '41.(92|93)',
    '41.(92|93)', 111.00;
test_sendrecv_params 'proposal/test_send_double_barrier.json', 'proposal/test_receive_double_barrier.json',
    'RANGE', 'frxXAUUSD', '7', 'd', '113', '108', 'Win payout if Gold/USD stays between 108.00 to 113.00 through close on 2016-08-16.', 55.9,
    '55.90', 111.00;

# frxUSDJPY 7 day CALL
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive.json',
    '100', 'CALL', 'frxUSDJPY', '7', 'd', 'Win payout if USD/JPY is strictly higher than entry spot at close on 2016-08-16.', '56.59', '56.59',
    97.14;

# R_100 Lookbacks
test_sendrecv_params 'proposal/test_send_lookback.json', 'proposal/test_receive_lookback.json',
    'LBFLOATCALL', 'R_100', '15', 'm', '', 'Win USD 10 times Volatility 100 Index\'s close minus low over the next 15 minutes.', '2750.00',
    '2750.00', 65258.19;

# R_100 touch tick trade
test_sendrecv_params 'proposal/test_send_single_barrier.json', 'proposal/test_receive_single_barrier.json',
    'ONETOUCH', 'R_100', '5', 't', '+20.5',
    'Win payout if Volatility 100 Index touches entry spot plus 20.50 through 5 ticks after first tick.', '44.81', '44.81', '65258.19';

# test for negative amount
test_sendrecv_params 'proposal/test_send.json', 'proposal/test_receive_negative.json', '-1', 'ASIANU', 'R_100', '5', 't';

# callput spread
test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'CALLSPREAD', 'frxUSDJPY', '7', 'd', '97.200', '97.150';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_offerings_validation_error.json',
    '100', 'PUTSPREAD', 'frxUSDJPY', '7', 'd', '97.200', '97.150';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_receive_callputspread.json',
    '100', 'CALLSPREAD', 'R_100', '7', 'd', '65258.00', '65208.19',
    'Win up to USD 100 if Volatility 100 Index\'s exit tick is between 65208.19 and 65258.00 at close on 2016-08-16.',
    '47.95', '47.95', '65258.19';

test_sendrecv_params 'proposal/test_send_callputspread.json', 'proposal/test_receive_callputspread.json',
    '100', 'PUTSPREAD', 'R_100', '7', 'd', '65258.00', '65208.19',
    'Win up to USD 100 if Volatility 100 Index\'s exit tick is between 65258.00 and 65208.19 at close on 2016-08-16.',
    '53.54', '53.54', '65258.19';

# multiplier
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'payout', '10',
    'ContractCreationFailure', 'Basis must be stake for this contract.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'frxUSDJPY', 'stake', '10',
    'OfferingsValidationError', 'Trading is not offered for this asset.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_error.json', 'MULTUP', 'R_100', 'stake', '5',
    'ContractBuyValidationError', 'Multiplier is not in acceptable range. Accepts 10,20,30,50,100.';
test_sendrecv_params 'proposal/test_send_multiplier.json', 'proposal/test_receive_multiplier.json', 'MULTUP', 'R_100', 'stake', '10',
    'Win 10% of your stake for every 1% rise in the market price.', '100.00', '100', '65258.19', 'Stop Out', '58765.26', '', '';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake', '10',
    'something', '1', 'InputValidationFailed', 'Input validation failed: limit_order';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake', '10',
    'take_profit', '-1', 'ContractBuyValidationError', 'Invalid take profit. Take profit must be higher than current spot price.';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_limit_order_error.json', 'MULTUP', 'R_100', 'stake', '10',
    'stop_loss', '1', 'ContractBuyValidationError', 'Invalid stop loss. Stop loss must be lower than current spot price.';
test_sendrecv_params 'proposal/test_send_multiplier_limit_order.json', 'proposal/test_receive_multiplier_limit_order.json', 'MULTUP', 'R_100', 'stake', '10',
    'stop_loss', '-1', 'Win 10% of your stake for every 1% rise in the market price.', '100.00', '100', '65258.19', 'Stop Out', '58765.26', 'Stop Loss', '65225.82';

#subscription
test_sendrecv_params 'proposal/test_send_subscribe.json', 'proposal/test_receive_subscribe.json',
    '100', 'ASIANU', 'R_100', '5', 't', 'Win payout if the last tick of Volatility 100 Index is strictly higher than the average of the 5 ticks.',
    '51.49', '51.49', '65258.19';

finish;
