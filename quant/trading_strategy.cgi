#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use f_brokerincludeall;
use Format::Util::Numbers qw( to_monetary_number_format );
use BOM::Platform::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

# BrokerPresentation('Trading strategy tests');

Bar('Trading strategy');

my @datasets = sort map $_->basename('.csv'), path('/var/lib/binary/trading_strategy_data/')->children;
my @strategies = qw(buy_and_hold mean_reversal bollinger);
BOM::Backoffice::Request::template->process(
    'backoffice/trading_strategy.html.tt', {
        dataset_list => \@datasets,
        strategy_list => \@strategies,
    }
);

code_exit_BO();
