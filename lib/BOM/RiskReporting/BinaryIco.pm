package BOM::RiskReporting::BinaryIco;

=head1 NAME

BOM::RiskReporting::BinaryIco

=head1 SYNOPSIS

BOM::RiskReporting::BinaryIco->new->generate_output_in_csv;

=cut

use strict;
use warnings;

local $\ = undef;    # Sigh.

use Moose;
extends 'BOM::RiskReporting::Base';

use BOM::Database::ClientDB;
use Time::Duration::Concise::Localize;
use BOM::Platform::Config;
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use BOM::Backoffice::Request;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_XSendfile PrintContentType_image);
use File::Temp;
use Chart::Gnuplot;
use List::MoreUtils qw(uniq);
use List::Util qw(max);

sub generate_output_in_csv {
    my $self = shift;

    my @fields = qw(
        client_loginid
        buy_price
        currency_code
        id
        number_of_tokens
        per_token_bid_price
        per_token_bid_price_USD
        short_code
        transaction_id
    );

    local $\ = "\n";
    my $filename = File::Temp->new(SUFFIX => '.csv')->filename;
    open my $fh, '>:encoding(UTF-8)', $filename;
    print $fh join(',', @fields);

    my $open_ico_ref = $self->live_open_ico;
    foreach my $c (sort keys %{$open_ico_ref}) {
        print $fh join(',', map { $open_ico_ref->{$c}->{$_} } @fields);
    }
    close $fh;

    PrintContentType_XSendfile($filename, 'application/octet-stream');
    return;

}

sub generate_output_in_histogram {
    my $self = shift;

    my $open_ico_ref = $self->live_open_ico;
    my @per_token_price;
    my @currency;

    my @all_currency_pairs = map { $open_ico_ref->{$_}->{currency_code} } keys %$open_ico_ref;
    my @uniq_currencies = uniq @all_currency_pairs;
    my @xy =
        sort { $b->[0] <=> $a->[0] }
        map { [$open_ico_ref->{$_}->{per_token_bid_price_USD}, $open_ico_ref->{$_}->{number_of_tokens}] } sort keys %$open_ico_ref;

    my $multiChart = Chart::Gnuplot->new(
        output    => get_tmp_path_or_die() . "/graph.png",
        imagesize => "3, 2.5",
    );

    my @charts = ();
    $charts[0][0] = Chart::Gnuplot->new(
        title => {
            text => "Histogram: All Open ICO deals converted into USD",
            font => "arial, 24"
        },
        xlabel => "Bid price per token in USD",
        ylabel => "Number of tokens",
        grid   => "off",

    );
    my $dataSet = Chart::Gnuplot::DataSet->new(
        points => \@xy,
        style  => "histograms",
        color  => "dark-green",
        fill   => {
            density => 0.2,
        },
    );
    $charts[0][0]->add2d($dataSet);

    my $i = 1;
    foreach my $currency (@uniq_currencies) {
        my @xy_1 =
            sort { $b->[0] <=> $a->[0] }
            map { [$open_ico_ref->{$_}->{per_token_bid_price}, $open_ico_ref->{$_}->{number_of_tokens}] }
            grep { $open_ico_ref->{$_}->{currency_code} eq $currency } sort keys %$open_ico_ref;

        my $max_token = max(map { $_->[1] } @xy_1);
        $charts[$i][0] = Chart::Gnuplot->new(
            title => {
                text => "Histogram: Open ICO deals in $currency",
                font => "arial, 24"
            },
            xlabel => "Bid price per token in $currency",
            ylabel => "Number of tokens",
            grid   => "off",
            yrange => [0, $max_token],

        );
        my $dataSet1 = Chart::Gnuplot::DataSet->new(
            color  => "blue",
            points => \@xy_1,
            title  => $currency,
            style  => "histograms",
            fill   => {
                density => 0.2,
            },
        );

        $charts[$i][0]->add2d($dataSet1);
        $i += 1;

    }

# Plot the multplot chart
    $multiChart->multiplot(\@charts);

    my $file = get_tmp_path_or_die() . "/graph.png";
    PrintContentType_image('png');
    binmode STDOUT;
    open(IMAGE, '<', $file);
    print <IMAGE>;
    close IMAGE;

    return;

}
no Moose;
__PACKAGE__->meta->make_immutable;
1;
