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
use BOM::Backoffice::Request;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_XSendfile PrintContentType_image);
use File::Temp;
use Chart::Gnuplot;
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

    local $\ = "\n";
    my $filename = File::Temp->new(SUFFIX => '.png')->filename;
    open my $fh, '>:encoding(UTF-8)', $filename;

    my $open_ico_ref = $self->live_open_ico;
    my @number_of_tokens;
    my @per_token_price;
    my @per_token_price_usd;
    foreach my $c (sort keys %{$open_ico_ref}) {
        push @number_of_tokens,    $open_ico_ref->{$c}->{number_of_tokens};
        push @per_token_price,     $open_ico_ref->{$c}->{per_token_bid_price};
        push @per_token_price_usd, $open_ico_ref->{$c}->{per_token_bid_price_USD};

    }
    my $chart = Chart::Gnuplot->new(
        output => $filename,
        title  => "Simple testing",
        xlabel => "Bid price per token",
        ylabel => "Number of token",
    );

    my $dataSet = Chart::Gnuplot::DataSet->new(
        xdata => \@per_token_price,
        ydata => \@number_of_tokens,
        title => "Histogram: Open ICO ",
        style => "histograms",
        using => "2:xticlabels(1)",
    );
    $chart->plot2d($dataSet);

    return;

}
no Moose;
__PACKAGE__->meta->make_immutable;
1;
