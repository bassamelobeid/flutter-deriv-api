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

use YAML qw(LoadFile);

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('Trading strategy tests');

Bar('Trading strategy');

my $hostname = Sys::Hostname::hostname();
if (BOM::System::Config::on_production() && $hostname !~ /^collector01/) {
    print "<h2>This must be run on collector01</h2>\n";
    code_exit_BO();
}

my $base_dir = '/var/lib/binary/trading_strategy_data/';
my $cgi      = request()->cgi;

my $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/trading_strategy_datasets.yml');

my @dates = sort map $_->basename, path($base_dir)->children;
warn "no dates" unless @dates;

my $date_selected = $cgi->param('date');
my $price_type_selected = $cgi->param('price_type') || 'ask';

my %strategies = map { ; $_ => 1 } Finance::TradingStrategy->available_strategies;
my $strategy_description;

my $strategy_name = $cgi->param('strategy');
warn "Invalid strategy provided" unless exists $strategies{$strategy_name};

my $count = $cgi->param('count') || 1;
my $skip  = $cgi->param('skip')  || 1;

my $rslt;
my @tbl;

my $process_dataset = sub {
    my ($date, $dataset) = @_;
    my $path = path($base_dir)->child($date)->child($dataset . '.csv');
    warn "date path not found: " . path($base_dir)->child($date) unless path($base_dir)->child($date)->exists;
    return unless $path->exists;

    my $strategy = Finance::TradingStrategy->new(
        strategy => $strategy_name,
        count    => $count,
    );

    $strategy_description = $strategy->description;
    my $fh  = $path->openr_utf8 or die "Could not open dataset $path - $!";
    my $sum = 0;
    my @hdr = qw(epoch quote buy_price value theo_price);
    my @results;
    my %stats;
    my @spots;
    my $line = 0;
    while (<$fh>) {
        next if $line++ % $skip;
        eval {
            my @market_data = split /\s*,\s*/;
            my %market_data = zip @hdr, @market_data;
            $market_data{buy_price} = $market_data{theo_price} if $price_type_selected eq 'theo';
            push @spots, $market_data{quote};
            # Each ->execute returns true (buy) or false (ignore), we calculate client profit from each one and maintain a sum
            my $should_buy = $strategy->execute(%market_data);
            $sum +=
                $should_buy
                ? ($market_data{value} - $market_data{buy_price})
                : 0;
            push @results, $sum;
            ++$stats{count};
            ++$stats{trades} if $should_buy;
            if ($market_data{value} > 0.001) {
                ++$stats{'winners'};
            } else {
                ++$stats{'losers'};
            }
            $stats{bought_buy_price}{sum} += $market_data{buy_price} if $should_buy;
            $stats{buy_price}{sum}        += $market_data{buy_price};
            $stats{payout}{mean}          += $market_data{value};
            $stats{start} ||= Date::Utility->new($market_data{epoch});
            $stats{end} ||= $stats{start} or die 'no start info? epoch was ' . $market_data{epoch};
            $stats{end} = Date::Utility->new($market_data{epoch}) if $market_data{epoch} > $stats{end}->epoch;
        } or do {
            warn "Error processing line $line - $@";
            1;
        };
    }
    if ($stats{count}) {
        $stats{buy_price}{mean} = $stats{buy_price}{sum} / $stats{count};
        $stats{sum_contracts_bought} = $sum;
        $stats{profit_margin} =
            $stats{bought_buy_price}{sum}
            ? sprintf '%.2f%%', -100.0 * $sum / $stats{bought_buy_price}{sum}
            : 'N/A';
        $stats{payout}{mean} /= $stats{count};
    }
    return {
        result_list => \@results,
        spot_list   => \@spots,
        statistics  => \%stats,
        dataset     => $dataset,
    };
};

my $statistics_table = sub {
    my $stats = shift;
    warn "bad stats - " . join(',', %$stats) unless exists $stats->{count};
    my $start_epoch = Date::Utility->new($stats->{start})->epoch;
    my $end_epoch   = Date::Utility->new($stats->{end})->epoch;
    return [
        ['Number of datapoints',   $stats->{count}],
        ['Starting date',          Date::Utility->new($stats->{start})->datetime],
        ['Ending date',            Date::Utility->new($stats->{end})->datetime],
        ['Period',                 Time::Duration::duration($end_epoch - $start_epoch)],
        ['Average buy price',      to_monetary_number_format($stats->{buy_price}{mean})],
        ['Average payout',         to_monetary_number_format($stats->{payout}{mean})],
        ['Number of winning bets', $stats->{winners}],
        ['Number of losing bets',  $stats->{losers}],
        ['Bets bought',            $stats->{trades}],
        ['Sum contracts bought',  sprintf '%.02f', $stats->{bought_buy_price}{sum}],
        ['Company profit',        sprintf '%.02f', -$stats->{sum_contracts_bought}],
        ['Company profit margin', $stats->{profit_margin}],
    ];
};

# When the button is pressed, we end up in here:
my ($underlying_selected) = $cgi->param('underlying') =~ /^(\w+|\*)$/;
my ($duration_selected)   = $cgi->param('duration') =~ /^(\w+|\*)$/;
my ($type_selected)       = $cgi->param('type') =~ /^(\w+|\*)$/;
if ($cgi->param('run')) {
    if (grep { $_ eq '*' } $underlying_selected, $duration_selected, $type_selected, $date_selected) {
        $rslt = {};
        TABLE:
        for my $underlying ($underlying_selected eq '*' ? @{$config->{underlyings}} : $underlying_selected) {
            for my $duration ($duration_selected eq '*' ? @{$config->{durations}} : $duration_selected) {
                for my $type ($type_selected eq '*' ? @{$config->{types}} : $type_selected) {
                    for my $date ($date_selected eq '*' ? @dates : $date_selected) {
                        my $dataset = join '_', $underlying, $duration, $type;
                        warn "will process dataset $dataset on $date";
                        push @tbl, eval { $process_dataset->($date, $dataset) } or do {
                            warn "Failed to process $dataset - $@" if $@;
                            ();
                        };
                        last TABLE if @tbl > 300;
                    }
                }
            }
        }
    } else {
        my $dataset = join '_', $underlying_selected, $duration_selected, $type_selected;
        $rslt = $process_dataset->($date_selected, $dataset);
    }
}

my %template_args = (
    parameter_list => {
        duration   => ['*', @{$config->{durations}}],
        date       => ['*', @dates],
        underlying => ['*', @{$config->{underlyings}}],
        type       => ['*', @{$config->{types}}],
    },
    selected_parameter => {
        date       => $date_selected,
        underlying => $underlying_selected,
        duration   => $duration_selected,
        type       => $type_selected,
        price_type => $price_type_selected,
    },
    count            => $count,
    skip             => $skip,
    strategy_list    => [sort keys %strategies],
    description      => $strategy_description,
    statistics       => $statistics_table->($rslt->{statistics}),
    result_list      => $rslt->{result_list},
    spot_list        => $rslt->{spot_list},
    dataset          => $rslt->{dataset},
    dataset_base_dir => '/trading_strategy_data',
    date             => $date_selected,
);

if (@tbl) {
    my @result_row;
    my $hdr;
    for my $result_for_dataset (@tbl) {
        my $stats = $statistics_table->($result_for_dataset->{statistics});
        $hdr //= $stats;
        push @result_row, [$result_for_dataset->{dataset}, map $_->[1], @$stats];
    }
    $template_args{result_table} = {
        header => ['Dataset', map $_->[0], @$hdr],
        body   => \@result_row,
    };
}

for my $k (qw(dataset strategy)) {
    my $param = $cgi->param($k);
    $template_args{$k . '_selected'} = $param if $param;
}

BOM::Backoffice::Request::template->process('backoffice/trading_strategy.html.tt', \%template_args);

code_exit_BO();
