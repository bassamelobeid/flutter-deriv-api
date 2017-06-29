package BOM::JapanContractDetailsOutput;

=head1 DESCRIPTION
This package is to output contract's pricing parameters that will be used by Japan team to replicate the contract price with the excel template. The format is as per required by the regulator. Please do not change it without confirmation from Quants and Japan team
=cut

use strict;
use warnings;
use lib qw(/home/git/regentmarkets/bom-backoffice);
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel PrintContentType_XSendfile);
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime;
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;
use Path::Tiny;
use Excel::Writer::XLSX;

sub output_on_display {
    my $contract_params = shift;
    PrintContentType();
    BOM::Backoffice::Request::template->process(
        'backoffice/contract_details.html.tt',
        {
            pricing_parameters => $contract_params,
        }) || die BOM::Backoffice::Request::template->error;
    return;
}

sub batch_output_as_excel {
    my $contract  = shift;
    my $file_name = shift;
    my $temp_file = get_tmp_path_or_die() . "/$file_name";
    my $workbook  = Excel::Writer::XLSX->new($temp_file);
    my $worksheet = $workbook->add_worksheet();
    my @combined;
    foreach my $c (sort keys %{$contract}) {
        my (@keys, @value);
        foreach my $key (sort values %{$contract->{$c}}) {
            push @keys,  keys %{$key};
            push @value, values %{$key};
        }

        push @combined, \@keys;
        push @combined, \@value;
    }

    $worksheet->write_row('A1', \@combined);
    $workbook->close;

    PrintContentType_XSendfile($temp_file, 'application/octet-stream');
    return;
}

sub single_output_as_excel {
    my $contract  = shift;
    my $file_name = shift;
    my $temp_file = get_tmp_path_or_die() . "/$file_name";
    my $workbook  = Excel::Writer::XLSX->new($temp_file);
    my $worksheet = $workbook->add_worksheet();
    my (@keys, @value);
    foreach my $key (sort keys %{$contract}) {
        push @keys,  keys %{$contract->{$key}};
        push @value, values %{$contract->{$key}};
    }
    my @combined = (\@keys, \@value);

    $worksheet->write_row('A1', \@combined);
    $workbook->close;

    PrintContentType_XSendfile($temp_file, 'application/octet-stream');
    return;
}

1;
