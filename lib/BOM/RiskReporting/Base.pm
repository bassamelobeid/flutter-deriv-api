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

use BOM::System::Localhost;
use BOM::Utility::CurrencyConverter qw(in_USD);

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

sub _build_end {
    return Date::Utility->new;
}

has _usd_rates => (
    is      => 'ro',
    builder => '_build__usd_rates',
);

sub _build__usd_rates {
    return {map { $_ => in_USD(1, $_) } BOM::Platform::Runtime->instance->landing_companies->all_currencies};
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

    my $cdb = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
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

before generate => sub {
    exit 0
        unless (BOM::System::Localhost::is_master_server());
};

sub generate {
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
