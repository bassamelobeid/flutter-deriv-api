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

sub _financial_assessment {
    my $self = shift;

    my %f;
    if ($self->client->financial_assessment) {
        my $h = JSON::XS::decode_json($self->client->financial_assessment->data);
        %f = map { $_ => $h->{$_}->{answer} } grep { ref $h->{$_} && $h->{$_}->{answer} } keys %$h;
    }
    return \%f;
}

sub _total_deposits_withdrawals {
    my $self = shift;

    my $total;
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({
        'client_loginid' => $self->client->loginid,
        'currency_code'  => $self->client->currency,
    });

    $total->{deposit}    = $payment_mapper->get_total_deposit_of_account;
    $total->{withdrawal} = $payment_mapper->get_total_withdrawal;
    $total->{balance}    = $self->client->default_account->balance;
    return $total;
}

sub get {
    my $self = shift;

    my $data = {};

    if (my $rows =
        $self->_db->dbh->selectrow_hashref("SELECT report FROM betonmarkets.risk_report WHERE client_loginid= ?", {}, $self->client->loginid))
    {
        $data = JSON::XS::decode_json($rows->{report});
    }

    return $data;
}

sub generate {
    my $self    = shift;
    my $clerk   = shift;
    my $comment = shift;

    my $data = $self->get;
    my $insert;
    $insert = 1 if (!keys %$data);

    my $time = time;
    $data->{client_details}                      = $self->_client_details;
    $data->{documents}                           = $self->_documents_on_file;
    $data->{country_change}                      = $self->_change_of_country;
    $data->{$time}->{financial_assessment}       = $self->_financial_assessment;
    $data->{$time}->{total_deposits_withdrawals} = $self->_total_deposits_withdrawals;
    $data->{$time}->{clerk}   = $clerk   if $clerk;
    $data->{$time}->{comment} = $comment if $comment;

    if ($insert) {
        my $sth = $self->_db->dbh->prepare("insert into betonmarkets.risk_report values ( ?, ?)");
        my $rows = $sth->execute($self->client->loginid, JSON::XS::encode_json($data));
    } else {
        my $sth = $self->_db->dbh->prepare("update betonmarkets.risk_report set report = ? where client_loginid = ?");
        my $rows = $sth->execute(JSON::XS::encode_json($data), $self->client->loginid);
    }

    return $data;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
