package BOM::RiskReporting::Client;

=head1 NAME

BOM::RiskReporting::Client

=head1 DESCRIPTION

Generates a client risk report

=cut

use strict;
use warnings;
use Moose;
extends 'BOM::RiskReporting::Base';
use BOM::Platform::User;
use Date::Utility;
use JSON::XS;

has client => (
    is => 'rw',
);

sub _client_details {
    my $self = shift;

    return {
        name              => $self->client->first_name . ' ' . $self->client->last_name,
        date_joined       => $self->client->date_joined,
        residence         => $self->client->residence,
        citizen           => $self->client->citizen || '',
        id_authentication => (
                   $self->client->get_authentication('ID_NOTARIZED')
                or $self->client->get_authentication('ID_DOCUMENT')
        ) ? 'yes' : 'no',
    };
}

sub _documents_on_file {
    my $self = shift;

    my @docs  = $self->client->client_authentication_document;
    my $count = 1;
    my $data  = {};
    for my $doc (@docs) {
        next if $doc->expiration_date && Date::Utility->new($doc->expiration_date)->is_before(Date::Utility->today);
        $data->{"document$count"} = $doc->document_type;
        $count++;
    }

    return $data;
}

sub _change_of_country {
    my $self = shift;

    my $user = BOM::Platform::User->new({email => $self->client->email});
    my $login_history = $user->find_login_history(
        sort_by => 'history_date',
    );
    my $count        = 0;
    my $last_country = '';
    my $data         = [];
    for my $h (@$login_history) {
        if ($h->environment =~ /IP=([0-9a-z\.:]+) IP_COUNTRY=([A-Z]{1,3})/ and $last_country ne $2) {
            $data->[$count]->{country}          = $2;
            $data->[$count]->{first_login_date} = $h->history_date->datetime;
            $last_country                       = $2;
            $count++;
        }
    }

    return $data;
}

sub _change_of_status {
    my $self = shift;

    my $db_data =
        $self->_db->dbh->selectall_hashref(q{SELECT * FROM audit.client_status where client_loginid=? order by id}, 'id', {}, $self->client->loginid);
    my $worksheet = $self->workbook->add_worksheet('change of status');
    $worksheet->write_row(0, 0, ['date', 'staff', 'status', 'reason']);
    my $count = 1;
    for my $key (sort keys %$db_data) {
        $worksheet->write($count, 0, $db_data->{$key}->{last_modified_date} || '');
        $worksheet->write($count, 1, $db_data->{$key}->{staff_name}         || '');
        $worksheet->write($count, 2, $db_data->{$key}->{status_code}        || '');
        $worksheet->write($count, 3, $db_data->{$key}->{reason}             || '');
        $count++;
    }
    return;
}

sub get {
    my $self = shift;

    my $data = {};

    return {};
}

sub _financial_assessment {
    my $self = shift;

    my $f;
    $f = JSON::XS::decode_json($self->client->financial_assessment->data) if $self->client->financial_assessment;
    return $f;
}

sub _total_deposits_withdrawals {
    my $self = shift;

    my $total;
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({
        'client_loginid' => $self->client->loginid,
        'currency_code'  => $self->client->currency,
    });

    $total->{deposit}    = $payment_mapper->get_total_deposit_of_account;
    $total->{withdrawal} = $payment_mapper->get_total_withdrawalk;
    return $total;
}

sub generate {
    my $self    = shift;
    my $clerk   = shift;
    my $comment = shift;

    my $data = $self->get;

    my $time = time;
    $data->{client_details}                      = $self->_client_details;
    $data->{documents}                           = $self->_documents_on_file;
    $data->{country_change}                      = $self->_change_of_country;
    $data->{$time}->{financial_assessment}       = $self->_financial_assessment;
    $data->{$time}->{total_deposits_withdrawals} = $self->_total_deposits_withdrawals;
    $data->{$time}->{clerk}   = $clerk if $clerk;
    $data->{$time}->{comment} = $comment if $comment;

    # $self->_change_of_status;
    # $self->_review_of_trades_bets;

    return $data;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
