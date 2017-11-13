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
    return {map { $_ => in_USD(1, $_) } grep { $_ !~ /^(?:ETC)$/ } LandingCompany::Registry->new()->all_currencies};
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

has live_open_ico => (
    isa        => 'HashRef',
    is         => 'ro',
    lazy_build => 1,
);

sub _build_live_open_ico {
    my $self = shift;
    my $live_open_ico = $self->_db->dbic->run(fixup => sub { $_->selectall_hashref(qq{ SELECT * FROM accounting.get_live_ico() }, 'id') });

    foreach my $c (keys %$live_open_ico) {
        $live_open_ico->{$c}->{per_token_bid_price_USD} =
            financialrounding('price', 'USD', in_USD($live_open_ico->{$c}->{per_token_bid_price}, $live_open_ico->{$c}->{currency_code}));

    }
    return $live_open_ico;

}

sub generate {
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
