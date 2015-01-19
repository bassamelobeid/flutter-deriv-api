package main;

#######################################################################
# IMPORTANT
#
# include_common_modules.pm should be used ONLY for mod_perl scripts
#
# It purposely tries to pre-load all modules at compilation time.
#
#######################################################################

use strict;
use File::Basename;
use File::Spec;

BEGIN {
    my $dir = File::Basename::dirname(File::Spec->rel2abs(__FILE__));
    unshift @INC, map { "$dir/$_" } (qw( ../lib .. oop ));
    use BOM::Platform::Runtime;
    BOM::Platform::Runtime->instance->app_config;
}

# Variables starting with GLOBALMODPERL_ are supposed to be globals
use vars qw(
    %GLOBALMODPERL_socketTCP_latesttry
    %GLOBALMODPERL_socketTCP

    $GLOBALMODPERL_LASTREFERER
    $GLOBALMODPERL_errorlogsocket
    $GLOBALMODPERL_lastsentdatagram
    $GLOBALMODPERL_errorlogsocket2
    $GLOBALMODPERL_lastwarning
);

########################################################
# Other subs
########################################################
use BOM::Platform::MyAffiliates::TrackingHandler;
use BOM::Platform::MyAffiliates::ExposureManager;
use BOM::Platform::MyAffiliates::BackfillManager;

use BOM::System::Password;
use BOM::Market::Exchange;
use BOM::Market::Underlying;

use BOM::MarketData::Display::EconomicEvent;
use BOM::Platform::Context qw(request localize);
use BOM::View::Utility qw(client_message);

use Math::Util::CalculatedValue::Validatable;

use BOM::Product::Contract::ContractCategory::ContractType::Helper::Barriers;
use BOM::Product::Contract::ContractCategory::ContractType;
use BOM::Utility::Date;
use BOM::System::Exceptions;
use BOM::Utility::Untaint;
use BOM::Platform::Client;
use BOM::Platform::Client::Attorney;
use BOM::Platform::Client::PaymentAgent;
use BOM::View::Controller::Bet;
use BOM::View::Controller::Bet::PriceBoxParameters;
use BOM::View::XHTMLMenu;

1;
