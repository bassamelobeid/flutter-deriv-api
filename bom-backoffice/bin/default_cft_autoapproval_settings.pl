#!/etc/rmg/bin/perl
use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::Redis;

my $redis_read = BOM::Config::Redis::redis_replicated_read();
my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $values_to_set = {};

$values_to_set->{'payments.autoapproval.cft.payment_methods'}                                                = ['CCPayout', 'CFT', 'CreditCard'];
$values_to_set->{'payments.autoapproval.cft.max_mt5_net_transfer'}                                           = 5000;
$values_to_set->{'payments.autoapproval.cft.max_mt5_net_transfer_enabled'}                                   = 1;
$values_to_set->{'payments.autoapproval.cft.max_pending_total'}                                              = 1000;
$values_to_set->{'payments.autoapproval.cft.max_pending_total_enabled'}                                      = 1;
$values_to_set->{'payments.autoapproval.cft.max_profit_day'}                                                 = 2000;
$values_to_set->{'payments.autoapproval.cft.max_profit_day_enabled'}                                         = 1;
$values_to_set->{'payments.autoapproval.cft.max_profit_month'}                                               = 5000;
$values_to_set->{'payments.autoapproval.cft.max_profit_month_enabled'}                                       = 1;
$values_to_set->{'payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_contracts_bought'}         = 0.25;
$values_to_set->{'payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_contracts_bought_enabled'} = 1;
$values_to_set->{'payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_mt5_transfers'}            = 0.25;
$values_to_set->{'payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_mt5_transfers_enabled'}    = 1;
$values_to_set->{'payments.autoapproval.cft.restricted_client_statuses'} =
    ['disabled', 'unwelcome', 'cashier_locked', 'withdrawal_locked', 'no_withdrawal_or_trading', 'only_pa_withdrawals_allowed'];
$app_config->set($values_to_set);

for my $key (keys $values_to_set->%*) {
    print $key . "\n";
    print $redis_read->get('app_settings::' . $key) . "\n\n";
}
