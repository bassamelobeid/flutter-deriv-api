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
use List::MoreUtils qw(zip);

use lib '/home/git/regentmarkets/perl-Finance-TradingStrategy/lib';
use Finance::TradingStrategy;
use Finance::TradingStrategy::BuyAndHold;

use Time::Duration ();

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('Trading strategy tests');

Bar('Trading strategy');

my $base_dir = '/var/lib/binary/trading_strategy_data/';
my $cgi = request()->cgi;
my @datasets = sort map $_->basename('.csv'), path($base_dir)->children;
my %strategies = map {; $_ => 1 } Finance::TradingStrategy->available_strategies;
my @results;
my %stats;
my @spots;
my $strategy_description;

my $count = $cgi->param('count');
if($cgi->param('run')) {
    my ($dataset) = $cgi->param('dataset') =~ /^(\w+)$/;
    die "Invalid dataset provided" unless $dataset eq $cgi->param('dataset');
    my $path = path($base_dir)->child($dataset);
    die "Dataset $path not found" unless $path->exists;

    my $strategy_name = $cgi->param('strategy');
    die "Invalid strategy provided" unless exists $strategies{$strategy_name};

    my $strategy = Finance::TradingStrategy->new(
        strategy => $strategy_name,
        count => $count,
    );

    $strategy_description = $strategy->description;
    my $fh = $path->openr_utf8 or die "Could not open dataset $path - $!";
    my $sum = 0;
    my @hdr = qw(epoch quote buy_price value);
    $stats{end} = 0;
    while(<$fh>) {
        my @market_data = split /\s*,\s*/;
        my %market_data = zip @hdr, @market_data;
        # Each ->execute returns true (buy) or false (ignore), we calculate client profit from each one and maintain a sum
        my $should_buy = $strategy->execute(%market_data);
        $sum += $should_buy
        ? ($market_data{value} - $market_data{buy_price})
        : 0;
        push @results, $sum;
        ++$stats{count};
        ++$stats{trades} if $should_buy;
        if($market_data{value} > 0.001) {
            ++$stats{'winners'};
        } else {
            ++$stats{'losers'};
        }
        $stats{bought_buy_price}{sum} += $market_data{buy_price} if $should_buy;
        $stats{buy_price}{sum} += $market_data{buy_price};
        $stats{payout}{mean} += $market_data{value};
        $stats{start} //= $market_data{epoch};
        $stats{end} = $market_data{epoch} if $market_data{epoch} > $stats{end};
    }
    if($stats{count}) {
        $stats{buy_price}{mean} = $stats{buy_price}{sum} / $stats{count};
        $stats{profit_margin} = sprintf '%.2f%%', -100.0 * $sum / $stats{bought_buy_price}{sum};
        $stats{payout}{mean} /= $stats{count};
    }
}

my %template_args = (
    dataset_list  => \@datasets,
    count => $count,
    strategy_list => [ sort keys %strategies ],
    result_list   => \@results,
    spot_list     => \@spots,
    description   => $strategy_description,
    statistics => [
        [ 'Number of datapoints', $stats{count} ],
        [ 'Starting date', Date::Utility->new($stats{start})->datetime ],
        [ 'Ending date' ,Date::Utility->new($stats{end})->datetime ],
        [ 'Period' , Time::Duration::duration($stats{end} - $stats{start}) ],
        [ 'Average buy price' ,$stats{buy_price}{mean} ],
        [ 'Average payout' ,$stats{payout}{mean} ],
        [ 'Number of winning bets' ,$stats{winners} ],
        [ 'Number of losing bets' ,$stats{losers} ],
        [ 'Bets bought' ,$stats{trades} ],
        [ 'Company profit margin', $stats{profit_margin} ],
    ]
);

for my $k (qw(dataset strategy)) {
    my $param = $cgi->param($k);
    $template_args{$k . '_selected'} = $param if $param;
}

BOM::Backoffice::Request::template->process(
    'backoffice/trading_strategy.html.tt',
    \%template_args
);

code_exit_BO();
