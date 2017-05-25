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
    is         => 'rw',
    lazy_build => 1,
);

sub _build_client {
    my $self = shift;
    return Client::Account::get_instance({'loginid' => $self->loginid});
}

has loginid => (
    is => 'rw',
);

has _update => (
    is => 'rw',
);

sub _client_details {
    my $self = shift;

    return {
        name              => $self->client->first_name . ' ' . $self->client->last_name,
        date_joined       => $self->client->date_joined,
        residence         => $self->client->residence,
        loginid           => $self->client->loginid,
        citizen           => $self->client->citizen || '',
        id_authentication => ($self->client->get_authentication('ID_NOTARIZED')) ? 'notorized'
        : ($self->client->get_authentication('ID_DOCUMENT')) ? 'scans'
        :                                                      'no',
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

sub _financial_assessment {
    my $self = shift;

    my @filter = qw(account_turnover education_level employment_industry estimated_worth income_source net_income occupation);
    my %f;
    if ($self->client->financial_assessment) {
        my $h = JSON::XS::decode_json($self->client->financial_assessment->data);
        %f = map { $_ => $h->{$_}->{answer} } @filter;
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
        $self->_update(1);
    }

    return $data;
}

sub _save {
    my $self = shift;
    my $data = shift;
    my $sth;
    if ($self->_update) {
        $sth = $self->_db->dbh->prepare('update betonmarkets.risk_report set report = $1 where client_loginid = $2');
    } else {
        $sth = $self->_db->dbh->prepare('insert into betonmarkets.risk_report values ($2, $1)');
    }
    $sth->execute(JSON::XS::encode_json($data), $self->client->loginid);
    return;
}

sub _comment {
    my $self    = shift;
    my $data    = shift;
    my $clerk   = shift;
    my $comment = shift;

    my $time = Date::Utility->new->datetime_ddmmmyy_hhmmss;
    if ($comment) {
        $data->{comments}->{$time}->{comment} = $comment;
        $data->{comments}->{$time}->{clerk}   = $clerk;
    }
    return;
}

sub _report {
    my $self  = shift;
    my $data  = shift;
    my $clerk = shift;

    my $time = Date::Utility->new->datetime_ddmmmyy_hhmmss;
    $data->{client_details}                                = $self->_client_details;
    $data->{documents}                                     = $self->_documents_on_file;
    $data->{country_change}                                = $self->_change_of_country;
    $data->{report}->{$time}->{financial_assessment}       = $self->_financial_assessment;
    $data->{report}->{$time}->{total_deposits_withdrawals} = $self->_total_deposits_withdrawals;
    $data->{report}->{$time}->{clerk} = $clerk if $clerk;
    return;
}

sub add_comment {
    my $self    = shift;
    my $clerk   = shift;
    my $comment = shift;

    my $data = $self->get;
    $self->_comment($data, $clerk, $comment) if $comment;

    $self->_save($data);
    return $data;
}

sub generate {
    my $self    = shift;
    my $clerk   = shift;
    my $comment = shift;

    my $data = $self->get;
    $self->_report($data, $clerk);
    $self->_comment($data, $clerk, $comment) if $comment;

    $self->_save($data);
    return $data;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
