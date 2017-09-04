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
while (defined(my $line = <DATA>)) {
    chomp $line;
    next if ($line =~ /^(#.*|)$/);
    $suite->exec_line($line, $.);
}
$suite->finish;
done_testing();

BEGIN { DATA->input_line_number(__LINE__ + 1) }    # ensure that $. reports physical line
__DATA__
# Connect in French
[FR]
# Doing a test that must fail
!payout_currencies/test_send.json,payout_currencies/test_receive_no_login_to_be_failed.json
!active_symbols/test_send_lc.json,active_symbols/test_receive_lc.json, 'costarica', 'forex', 'major_pairs'
!asset_index/test_send.json,asset_index/test_receive_to_fail.json
!landing_company/test_send.json,landing_company/test_receive_de.json, 'id'
!landing_company_details/test_send.json,landing_company_details/test_receive_costarica.json, 'virtual'

# Reconnect in English
[EN]

ping/test_send.json,ping/test_receive.json
time/test_send.json,time/test_receive.json
landing_company/test_send.json,landing_company/test_receive_de.json, 'de'
landing_company/test_send.json,landing_company/test_receive_id.json, 'id'
landing_company/test_send.json,landing_company/test_receive_jp.json, 'jp'
landing_company_details/test_send.json,landing_company_details/test_receive_costarica.json, 'costarica'
landing_company_details/test_send.json,landing_company_details/test_receive_virtual.json, 'virtual'
landing_company_details/test_send.json,landing_company_details/test_receive_iom.json, 'iom'
landing_company_details/test_send.json,landing_company_details/test_receive_japan.json, 'japan'
landing_company_details/test_send.json,landing_company_details/test_receive_japan_virtual.json, 'japan-virtual'
landing_company_details/test_send.json,landing_company_details/test_receive_malta.json, 'malta'
landing_company_details/test_send.json,landing_company_details/test_receive_maltainvest.json, 'maltainvest'
landing_company_details/test_send.json,landing_company_details/test_receive_error.json, 'unknown'
website_status/test_send.json,website_status/test_receive.json
payout_currencies/test_send.json,payout_currencies/test_receive_no_login.json
ticks_history/test_send_r50.json,ticks_history/test_receive_r50.json
active_symbols/test_send.json,active_symbols/test_receive_brief.json,'brief'
# active_symbols/test_send.json,active_symbols/test_receive_full.json,'full'
active_symbols/test_send_lc.json,active_symbols/test_receive_lc.json,'japan', 'forex', 'major_pairs'
active_symbols/test_send_lc.json,active_symbols/test_receive_lc.json,'malta', 'volidx', '.*'
active_symbols/test_send_lc.json,active_symbols/test_receive_lc.json,'maltainvest', '(?!^volidx$)(^.*$)', '.*'
asset_index/test_send.json,asset_index/test_receive.json
trading_times/test_send.json,trading_times/test_receive.json
# paymentagent_list/test_send.json,paymentagent_list/test_receive.json
residence_list/test_send.json,residence_list/test_receive.json
states_list/test_send.json,states_list/test_receive.json
