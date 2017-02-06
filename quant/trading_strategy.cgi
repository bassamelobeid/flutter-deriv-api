#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

no indirect;

use f_brokerincludeall;
use Format::Util::Numbers qw( to_monetary_number_format );
use BOM::Platform::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use List::MoreUtils qw(zip);
use List::Util qw(min max);
use List::UtilsBy qw(nsort_by);

use lib '/home/git/regentmarkets/perl-Finance-TradingStrategy/lib';
use Finance::TradingStrategy;
use Finance::TradingStrategy::BuyAndHold;
use Statistics::LineFit;

use Time::Duration ();

use YAML qw(LoadFile);

BOM::Backoffice::Sysinit::init();

PrintContentType();

my $base_dir = '/var/lib/binary/trading_strategy_data/';

my $cgi      = request()->cgi;
if(my $download = $cgi->param('download')) {
    my ($date, $dataset) = $download =~ m{^(\d{4}-\d{2}-\d{2})/([0-9a-zA-Z_]{4,20})$} or die 'invalid file';

    my $path = path($base_dir)->child($date)->child($dataset . '.csv');
    print "<pre>";
    print "epoch,spot,ask_price,expiry_price,theo_price\n";
    print for $path->lines_utf8;
    print "</pre>";
    code_exit_BO();
}

BrokerPresentation('Trading strategy tests');

Bar('Trading strategy');

my $hostname = Sys::Hostname::hostname();
if (BOM::System::Config::on_production() && $hostname !~ /^collector01/) {
    print '<h2>This must be run on <a href="https://backoffice.binary.com/d/backoffice/quant/trading_strategy.cgi">collector01.binary.com</a></h2>';
    code_exit_BO();
}

my $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/trading_strategy_datasets.yml');

my @dates = sort map $_->basename, path($base_dir)->children or do {
    print "<h2>No data found, please check whether the update_trading_strategy_data cronjob is enabled on this server</h2>\n";
    code_exit_BO();
};

my @date_selected = $cgi->param('date');
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
    my ($date_selected, $dataset_selected) = @_;
    $date_selected = [ $date_selected ] unless ref $date_selected;
    $dataset_selected = [ $dataset_selected ] unless ref $dataset_selected;
    my @results;
    my %stats;
    $stats{file_size} = 0;
    my @spots;
    my $sum = 0;
    DATE:
    for my $date (@$date_selected) {
        warn "date path not found: " . path($base_dir)->child($date) unless path($base_dir)->child($date)->exists;

        # Pull in all data first
        my @data;
        TYPE:
        for my $dataset (@$dataset_selected) {
            warn "Trying dataset $dataset\n";
            my $path = path($base_dir)->child($date)->child($dataset . '.csv');
            next DATE unless $path->exists;
            push @data, $path->lines_utf8;
            $stats{file_size} += -s $path;
        }

        # Ensure our graphs are ordered by epoch timestamp
        @data = nsort_by { (split /,/)[0] } @data;

        my $strategy = Finance::TradingStrategy->new(
            strategy => $strategy_name,
            count    => $count,
        );
        $strategy_description = $strategy->description;
        my @hdr = qw(epoch quote buy_price value theo_price);
        {
            my @info = split '_', $dataset_selected->[0];
            unshift @info, join '_', splice(@info, 0, 2) if $info[0] eq 'R';
            ($stats{symbol}, $stats{duration}, $stats{step_size}) = @info;
        }
        my $line = 0;

        for(@data) {
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
                $stats{buy_price}{min} //= $market_data{buy_price};
                $stats{buy_price}{max} //= $market_data{buy_price};
                $stats{buy_price}{min}         = min $stats{buy_price}{min}, $market_data{buy_price};
                $stats{buy_price}{max}         = max $stats{buy_price}{max}, $market_data{buy_price};
                $stats{payout}{mean}          += $market_data{value};
                $stats{payout}{sum}           += $market_data{value};

                $stats{start} ||= Date::Utility->new($market_data{epoch});
                $stats{end} ||= $stats{start} or die 'no start info? epoch was ' . $market_data{epoch};
                $stats{end} = Date::Utility->new($market_data{epoch}) if $market_data{epoch} > $stats{end}->epoch;
                1;
            } or do {
                warn "Error processing $line - (data $_) $@";
                1;
            };
        }
    }
    $stats{file_size} = '(' . $stats{file_size} . '&nbsp;bytes)';
    if ($stats{count}) {
        my $lf  = Statistics::LineFit->new;
        my $min = min @results;
        my $max = max @results;
        $lf->setData([1 .. @results], [map { ; ($_ - $min) / ($max - $min) } @results]) or warn "invalid ->setData";
        $stats{regression}           = $lf->meanSqError;
        $stats{buy_price}{mean}      = $stats{buy_price}{sum} / $stats{count};
        $stats{sum_contracts_bought} = $sum;
        $stats{profit_margin} =
            $stats{bought_buy_price}{sum}
        ? sprintf '%.2f%%', -100.0 * $sum / $stats{bought_buy_price}{sum}
        : 'N/A';
        $stats{payout}{mean} /= $stats{count};
    }
    if(@spots > 50_000) {
        my $spot_skip = 1 + int(@spots / 50_000);
        {
            my @output_spots;
            my @output_results;
            for(my $idx = 0; $idx < @spots; $idx += $spot_skip) {
                push @output_spots, $spots[$idx];
                push @output_results, $results[$idx];
            }
            @spots = @output_spots;
            @results = @output_results;
        }
    }

    return {
        result_list => \@results,
        spot_list   => \@spots,
        statistics  => \%stats,
        dataset     => join(' ', @$dataset_selected),
    };
};

my $statistics_table = sub {
    my $stats = shift;
    warn "bad stats - " . join(',', %$stats) unless exists $stats->{count};
    my $start_epoch = Date::Utility->new($stats->{start})->epoch;
    my $end_epoch   = Date::Utility->new($stats->{end})->epoch;
    return [
        ['# of bets',              $stats->{count} . '<br>' . $stats->{file_size}],
        ['Step size',              $stats->{step_size}],
        ['Starting date',          Date::Utility->new($stats->{start})->datetime],
        ['Ending date',            Date::Utility->new($stats->{end})->datetime],
        ['Period',                 Time::Duration::duration($end_epoch - $start_epoch)],
        ['Average buy price',      to_monetary_number_format($stats->{buy_price}{mean}) . '<br>' . ('(' . to_monetary_number_format($stats->{buy_price}{min}) . '/' . to_monetary_number_format($stats->{buy_price}{max}) . ')')],
        ['Average payout',         to_monetary_number_format($stats->{payout}{mean})],
        ['Number of winning bets', $stats->{winners}],
        ['Number of losing bets',  $stats->{losers}],
        ['Bets bought',            $stats->{trades}],
        ['Sum of payouts',         sprintf '%.02f', $stats->{payout}{sum}],
        ['Sum contracts bought',   sprintf '%.02f', $stats->{bought_buy_price}{sum} // 0],
        ['Company profit',         sprintf '%.02f', -($stats->{sum_contracts_bought} // 0)],
        ['Company profit margin', $stats->{profit_margin} // 0],
        ['Normalised Least Squares', sprintf '%.04f', 100.0 * $stats->{regression} // 0],
    ];
};

# When the button is pressed, we end up in here:
my ($underlying_selected) = $cgi->param('underlying') =~ /^(\w+|\*)$/;
my ($duration_selected)   = $cgi->param('duration') =~ /^([\w ]+|\*)$/;
my (@type_selected)       = grep /^(\w+|\*)$/, $cgi->param('type');
if ($cgi->param('run')) {
    if (grep { $_ eq '*' } $underlying_selected, $duration_selected, @type_selected, @date_selected) {
        @date_selected = @dates if grep { $_ eq '*' } @date_selected;
        @type_selected = @{$config->{types}} if grep { $_ eq '*' } @type_selected;
        $rslt = {};
        TABLE:
        for my $underlying ($underlying_selected eq '*' ? @{$config->{underlyings}} : $underlying_selected) {
            for my $duration_line ($duration_selected eq '*' ? @{$config->{durations}} : $duration_selected) {
                (my $duration = $duration_line) =~ s/ step /_/;
                for my $type (@type_selected) {
                    my $dataset = join '_', $underlying, $duration, $type;
                    push @tbl, eval { $process_dataset->([ @date_selected ], $dataset) } or do {
                        print "Failed to process $dataset - $@" if $@;
                        ();
                    };
                    last TABLE if @tbl > 300;
                }
            }
        }
    } else {
        @date_selected = @dates if grep { $_ eq '*' } @date_selected;
        @type_selected = @{$config->{types}} if grep { $_ eq '*' } @type_selected;
        my $dataset = [ map {; join '_', $underlying_selected, ($duration_selected =~ s/ step /_/r), $_ } @type_selected ];
        $rslt = $process_dataset->(\@date_selected, $dataset);
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
        date       => [ @date_selected ],
        underlying => $underlying_selected,
        duration   => $duration_selected,
        type       => [ @type_selected ],
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
    date             => $date_selected[0],
);

if (@tbl) {
    my @result_row;
    my $hdr;
    for my $result_for_dataset (@tbl) {
        my $stats = $statistics_table->($result_for_dataset->{statistics});
        $hdr //= $stats;

        my @info = split '_', $result_for_dataset->{dataset};
        unshift @info, join '_', splice(@info, 0, 2) if $info[0] eq 'R';

        my @hdr = qw(Symbol Duration Step Type);
        my %details = zip @hdr, @info;
        splice(@hdr, 2, 1);

        my $date = Date::Utility->new($result_for_dataset->{statistics}{start})->date;
        push @result_row,
            [
            '<a target="_blank" href="/d/backoffice/quant/trading_strategy.cgi?date='
                . $date
                . '&underlying='
                . $details{Symbol}
                . '&duration='
                . $details{Duration}
                . '%20step%20'
                . $details{Step}
                . '&count='
                . $count
                . '&skip='
                . $skip
                . '&strategy='
                . $strategy_name
                . '&type='
                . $details{Type} . '">'
                . join(" ", map $details{$_}, grep exists $details{$_}, @hdr) . '</a>',
            map $_->[1],
            @$stats
            ];
    }
    $template_args{result_table} = {
        header => ['Bet', map $_->[0], @$hdr],
        body   => \@result_row,
    };
}

for my $k (qw(dataset strategy)) {
    my $param = $cgi->param($k);
    $template_args{$k . '_selected'} = $param if $param;
}

my $tt = BOM::Backoffice::Request::template;
$tt->process('backoffice/trading_strategy.html.tt', \%template_args) or warn $tt->error;

code_exit_BO();
