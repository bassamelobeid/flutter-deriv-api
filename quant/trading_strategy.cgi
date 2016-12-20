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

BOM::Backoffice::Sysinit::init();

PrintContentType();

# BrokerPresentation('Trading strategy tests');

Bar('Trading strategy');

my $base_dir = '/var/lib/binary/trading_strategy_data/';
my $cgi = request()->cgi;
my @datasets = sort map $_->basename('.csv'), path($base_dir)->children;
my %strategies = map {; $_ => 1 } qw(buy_and_hold mean_reversal bollinger);
my @results;
if($cgi->param('run')) {
    my ($dataset) = $cgi->param('dataset') =~ /^(\w+)$/;
    die "Invalid dataset provided" unless $dataset eq $cgi->param('dataset');
    my $path = path($base_dir)->child($dataset);
    die "Dataset $path not found" unless $path->exists;

    my $strategy_name = $cgi->param('strategy');
    die "Invalid strategy provided" unless exists $strategies{$strategy_name};

    my $strategy = Finance::TradingStrategy->new(
        strategy => $strategy_name,
    );

    my $fh = $path->openr_utf8 or die "Could not open dataset $path - $!";
    my $sum = 0;
    my @hdr = qw(epoch quote buy_price value);
    while(<$fh>) {
        my @market_data = split /\s*,\s*/;
        my %market_data = zip @hdr, @market_data;
        $sum += $strategy->execute(%market_data);
        push @results, $sum;
    }
}

my %template_args = (
    dataset_list  => \@datasets,
    strategy_list => [ sort keys %strategies ],
    result_list   => \@results,
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
