package BOM::Database::AutoGenerated::Rose::Audit::FinancialMarketBet::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::Audit::FinancialMarketBet;

sub object_class { 'BOM::Database::AutoGenerated::Rose::Audit::FinancialMarketBet' }

__PACKAGE__->make_manager_methods('financial_market_bet');

1;

