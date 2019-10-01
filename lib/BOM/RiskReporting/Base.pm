package BOM::RiskReporting::Base;

=head1 NAME

BOM::RiskReporting::Base

=head1 DESCRIPTION

A generic base class for risk reporting modules. 
=head1 SYNOPSIS

BOM::RiskReport::Base->new->generate;

=cut

use strict;
use warnings;

use BOM::Config;
use ExchangeRates::CurrencyConverter qw(in_usd);

use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;

local $\ = undef;    # Sigh.

use Moose;

has [qw( end )] => (
    is         => 'ro',
    isa        => 'Date::Utility',
    lazy_build => 1,
);

has send_alerts => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

has client => (
    is => 'rw',
);

sub _db_broker_code {
    my $self = shift;
    return 'FOG' if not $self->client;
    return $self->client->broker;
}

sub _db_operation {
    my $self = shift;
    return ($self->_db_broker_code eq 'FOG') ? 'collector' : 'backoffice_replica';
}

sub _build_end {
    return Date::Utility->new;
}

has _usd_rates => (
    is      => 'ro',
    builder => '_build__usd_rates',
);

sub _build__usd_rates {
    return {map { $_ => in_usd(1, $_) } LandingCompany::Registry->new()->all_currencies()};
}

sub amount_in_usd {
    my ($self, $amount, $currency) = @_;

    return $amount * $self->_usd_rates->{uc $currency};
}

sub _db {
    my $self = shift;

    my $cdb = BOM::Database::ClientDB->new({
        broker_code => $self->_db_broker_code,
        operation   => $self->_db_operation,
    });
    $cdb->db->connect_option(
        Callbacks => {
            connected => sub {
                shift->do("SET statement_timeout TO 0");
                return;
            }
        });
    # Maybe the connection got from cache, set it for safe
    $cdb->db->dbic->run(fixup => sub { $_->do("SET statement_timeout TO 0") });
    return $cdb->db;
}

sub _db_write {
    my $self = shift;
    return BOM::Database::ClientDB->new({
            broker_code => $self->client->broker,
            operation   => 'write',
        })->db;
}

has live_open_bets => (
    isa        => 'HashRef',
    is         => 'ro',
    lazy_build => 1,
);

sub _build_live_open_bets {
    my $self = shift;
    return $self->_db->dbic->run(fixup => sub { $_->selectall_hashref(qq{ SELECT * FROM accounting.get_live_open_bets() }, 'id') });
}

sub historical_open_bets {
    my ($self, $date) = @_;

    return $self->_db->dbic->run(
        fixup => sub {
            $_->selectall_hashref(
                qq{ SELECT id, loginid AS client_loginid, currency_code, short_code, buy_price, ref AS transaction_id
FROM accounting.get_historical_open_bets_overview_v2(?::TIMESTAMP)}, 'id', {}, $date
            );
        });
}

sub closed_PL_by_underlying {
    my ($self, $date) = @_;

    return $self->_db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(qq{ SELECT * FROM accounting.get_closed_pl_by_underlying(?)}, {}, $date);
        });

}

sub generate {
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
