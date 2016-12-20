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

    my $fh = $path->openr_utf8 or die "Could not open dataset $path - $!";
    my $sum = 0;
    my @hdr = qw(epoch quote buy_price value);
    while(<$fh>) {
        my @quote = split /\s*,\s*/;
        my %quote = zip @hdr, @quote;
        # $strategy->execute(...)
        $sum += $quote{value} - $quote{buy_price};
        push @results, $sum;
    }
}

BOM::Backoffice::Request::template->process(
    'backoffice/trading_strategy.html.tt', {
        dataset_list => \@datasets,
        strategy_list => [ sort keys %strategies ],
        result_list => \@results,
    }
);

code_exit_BO();
