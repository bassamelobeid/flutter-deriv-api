use strict;
use warnings;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

start(
    title             => 'assets.t',
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

# Connect in French
set_language 'FR';

# Doing a test that must fail
fail_test_sendrecv 'payout_currencies/test_send.json',        'payout_currencies/test_receive_no_login_to_be_failed.json';
fail_test_sendrecv_params 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json', 'svg', 'forex', 'major_pairs';
fail_test_sendrecv 'asset_index/test_send.json',              'asset_index/test_receive_to_fail.json';
fail_test_sendrecv_params 'landing_company/test_send.json',         'landing_company/test_receive_de.json',          'id';
fail_test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_svg.json', 'virtual';

# Reconnect in English
set_language 'EN';

test_sendrecv 'ping/test_send.json', 'ping/test_receive.json';
test_sendrecv 'time/test_send.json', 'time/test_receive.json';

test_sendrecv_params 'landing_company/test_send.json', "landing_company/test_receive_$_.json", $_ foreach qw( de id );

test_sendrecv_params 'landing_company_details/test_send.json', "landing_company_details/test_receive_$_.json", $_
    foreach qw( svg virtual iom malta maltainvest );

# This file doesn't follow the same naming pattern
test_sendrecv_params 'landing_company_details/test_send.json', "landing_company_details/test_receive_error.json", 'unknown';

test_sendrecv 'website_status/test_send.json',           'website_status/test_receive.json';
test_sendrecv 'website_status/test_send_subscribe.json', 'website_status/test_receive_subscribe.json';

test_sendrecv 'payout_currencies/test_send.json', 'payout_currencies/test_receive_no_login.json';
test_sendrecv 'ticks_history/test_send_r50.json', 'ticks_history/test_receive_r50.json';

test_sendrecv_params 'active_symbols/test_send.json', 'active_symbols/test_receive_brief.json', 'brief';
# test_sendrecv_params 'active_symbols/test_send.json', 'active_symbols/test_receive_full.json',
#     'full';

test_sendrecv_params 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json', 'malta',       'volidx',             '.*';
test_sendrecv_params 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json', 'maltainvest', '(?!^volidx$)(^.*$)', '.*';

test_sendrecv 'asset_index/test_send.json',    'asset_index/test_receive.json';
test_sendrecv 'trading_times/test_send.json',  'trading_times/test_receive.json';
test_sendrecv 'residence_list/test_send.json', 'residence_list/test_receive.json';
test_sendrecv 'states_list/test_send.json',    'states_list/test_receive.json';

finish;
