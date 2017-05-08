package BOM::RiskReporting::Dashboard;

=head1 NAME

BOM::RiskReporting::Client

=head1 DESCRIPTION

Generates a client risk report

=cut

use strict;
use warnings;
extends 'BOM::RiskReporting::Base';

use Excel::Writer::XLSX;
use File::Temp qw(tempfile);

has workbook => (
    lazy_build => 1,
    default => {  },
);

has client => (
);

sub _build_workbook {
    my (undef, $filename) = tempfile();
    return Excel::Writer::XLSX->new($filename);
}

sub generate {
    my $self = shift;
    my $loginid = shift;

    $self->db_broker_code($self->client->broker);

    $self->_client_details;
    $self->_total_deposits_withdrawals;
    $self->_documents_on_file;
    $self->_financial_assessment_results;
    $self->_change_of_IP;
    $self->_change_of_status;
    $self->_review_of_trades_bets;
    $self->_comments;

    return $self->_report;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
