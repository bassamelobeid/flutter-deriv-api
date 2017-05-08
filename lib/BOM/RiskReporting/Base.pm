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

use BOM::Platform::Config;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use LandingCompany::Registry;

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

has db_broker_code => (
    default => sub {'FOG'},
);

has _db_operation => (
    is      => 'rw',
    default => sub {(shift->db_broker_code =='FOG')? 'collector': 'replica'},
);

sub _build_end {
    return Date::Utility->new;
}

has _usd_rates => (
    is      => 'ro',
    builder => '_build__usd_rates',
);

sub _build__usd_rates {
    return {map { $_ => in_USD(1, $_) } LandingCompany::Registry->new()->all_currencies};
}

sub amount_in_usd {
    my ($self, $amount, $currency) = @_;

    return $amount * $self->_usd_rates->{uc $currency};
}

sub _db {
    return shift->_connection_builder->db;
}

has _connection_builder => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__connection_builder {
    my $self = shift;

    my $cdb = BOM::Database::ClientDB->new({
        broker_code => self->db_broker_code,
        operation   => self->_db_operation,
    });
    $cdb->db->dbh->do("SET statement_timeout TO 0");
    return $cdb;
}

has live_open_bets => (
    isa        => 'HashRef',
    is         => 'ro',
    lazy_build => 1,
);

sub _build_live_open_bets {
    my $self = shift;
    return $self->_db->dbh->selectall_hashref(qq{ SELECT * FROM accounting.get_live_open_bets() }, 'id');
}

sub generate {
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
