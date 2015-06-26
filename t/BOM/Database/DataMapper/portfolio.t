#!/usr/bin/perl
package t::Portfolio;

# PURPOSE: Perform unit tests on the open bets related subroutines (in Subs_openpos.pm).
#
# EXECUTION: How to run (from any directory) -
#  /> su nobody -c 'prove /home/git/regentmarkets/bom/cgi/t/Portfolio/001_portfolio.t'
#
# to see tests that are passed and comments add -v flag, i.e use:
#  /> su nobody -c 'prove -v /home/git/regentmarkets/bom/cgi/t/Portfolio/001_portfolio.t'
#
# to run every test script inside folder, & see tests that are passed and comments add -v flag, i.e use:
# This will run all test script inside this folder, in alphabetical order base on test script file name
#  /> su nobody -c "prove -v /home/git/regentmarkets/bom/cgi/t/*"
##########################################################################################################

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../..";    #cgi
use Test::More qw(no_plan);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $loginID  = 'CR0014';
my $currency = 'GBP';

# Testing open bets
my $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
    'client_loginid' => $loginID,
    'currency_code'  => $currency
});
my $open_bets = $bet_mapper->get_open_bets_of_account();

my $number_of_open_bets = scalar @{$open_bets};
is($number_of_open_bets, 2, 'The total number of open bets is ' . $number_of_open_bets);

