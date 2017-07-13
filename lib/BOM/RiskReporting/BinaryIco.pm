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

    my $data;
    my @all_currency_pairs = map { $open_ico_ref->{$_}->{currency_code} } keys %$open_ico_ref;
    my @uniq_currencies = uniq @all_currency_pairs;
    my @xy =
        map { [$open_ico_ref->{$_}->{per_token_bid_price_USD}, $open_ico_ref->{$_}->{number_of_tokens}] } sort keys %$open_ico_ref;

    $data->{converted_in_usd} = \@xy;
    foreach my $currency (@uniq_currencies) {
        my @xy_1 =
            map { [$open_ico_ref->{$_}->{per_token_bid_price}, $open_ico_ref->{$_}->{number_of_tokens}] }
            grep { $open_ico_ref->{$_}->{currency_code} eq $currency } sort keys %$open_ico_ref;

        $data->{$currency} = \@xy_1;
    }

    return $data;

}
no Moose;
__PACKAGE__->meta->make_immutable;
1;
