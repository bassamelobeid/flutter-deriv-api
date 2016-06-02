#!/usr/bin/perl

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::PricingDetails;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Bet Price Over Time');
BOM::Backoffice::Auth0::can_access(['Quants']);

Bar("Bet Parameters");
code_exit_BO();
