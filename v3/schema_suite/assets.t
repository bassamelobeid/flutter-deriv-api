use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite;

my $dir_path = __DIR__;

my $suite = BOM::Test::Suite->new(
    title             => 'assets.t',
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => $dir_path . '/config/',
);

# Some DSL-like functions that can be moved into a shared module at some point
sub test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    $suite->exec_test(
        send_file     => $send_file,
        receive_file  => $receive_file,
        linenum       => (caller)[2],
        %args,
    );
}
sub fail_test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    test_sendrecv($send_file, $receive_file, %args,
        expect_fail   => 1,
        linenum       => (caller)[2],
    );
}

# Connect in French
$suite->set_language('FR');

# Doing a test that must fail
fail_test_sendrecv 'payout_currencies/test_send.json', 'payout_currencies/test_receive_no_login_to_be_failed.json';
fail_test_sendrecv 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json',
    template_func => [qw[ 'costarica'  'forex'  'major_pairs' ]];
fail_test_sendrecv 'asset_index/test_send.json', 'asset_index/test_receive_to_fail.json';
fail_test_sendrecv 'landing_company/test_send.json', 'landing_company/test_receive_de.json',
    template_func => [qw[ 'id' ]];
fail_test_sendrecv 'landing_company_details/test_send.json', 'landing_company_details/test_receive_costarica.json',
    template_func => [qw[ 'virtual' ]];


# Reconnect in English
$suite->set_language('EN');

test_sendrecv 'ping/test_send.json', 'ping/test_receive.json';
test_sendrecv 'time/test_send.json', 'time/test_receive.json';

test_sendrecv 'landing_company/test_send.json', "landing_company/test_receive_$_.json",
    template_func => [ "'$_'" ] foreach qw( de id jp );

test_sendrecv 'landing_company_details/test_send.json', "landing_company_details/test_receive_$_.json",
    template_func => [ "'$_'" ] foreach qw( costarica virtual iom japan malta maltainvest );

# These files don't follow the same naming pattern
test_sendrecv 'landing_company_details/test_send.json', "landing_company_details/test_receive_japan_virtual.json",
    template_func => [ "'japan-virtual'" ];
test_sendrecv 'landing_company_details/test_send.json', "landing_company_details/test_receive_error.json",
    template_func => [ "'unknown'" ];

test_sendrecv 'website_status/test_send.json', 'website_status/test_receive.json';
test_sendrecv 'payout_currencies/test_send.json', 'payout_currencies/test_receive_no_login.json';
test_sendrecv 'ticks_history/test_send_r50.json', 'ticks_history/test_receive_r50.json';

test_sendrecv 'active_symbols/test_send.json', 'active_symbols/test_receive_brief.json',
    template_func => [ "'brief'" ];
# test_sendrecv 'active_symbols/test_send.json', 'active_symbols/test_receive_full.json',
#     template_func => [ "'full'" ];

test_sendrecv 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json',
    template_func => [qw[ 'japan' 'forex' 'major_pairs' ]];
test_sendrecv 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json',
    template_func => [qw[ 'malta' 'volidx' '.*' ]];
test_sendrecv 'active_symbols/test_send_lc.json', 'active_symbols/test_receive_lc.json',
    template_func => [qw[ 'maltainvest' '(?!^volidx$)(^.*$)' '.*' ]];

test_sendrecv 'asset_index/test_send.json', 'asset_index/test_receive.json';
test_sendrecv 'trading_times/test_send.json', 'trading_times/test_receive.json';
# test_sendrecv 'paymentagent_list/test_send.json', 'paymentagent_list/test_receive.json';
test_sendrecv 'residence_list/test_send.json', 'residence_list/test_receive.json';
test_sendrecv 'states_list/test_send.json', 'states_list/test_receive.json';

$suite->finish;
done_testing();
