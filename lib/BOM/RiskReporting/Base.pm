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
use BOM::Config::CurrencyConfig;
use ExchangeRates::CurrencyConverter qw(in_usd);

use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;
use Log::Any qw($log);
use Syntax::Keyword::Try;

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

=head2 client_dbs

A hash reference of all client dbs. It's been created by going through the brokers.
Multiple brokers on the same clientdb are excluded.

=cut

has all_client_dbs => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy_build => 1,
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
    return {
        map      { $_ => in_usd(1, $_) }
            grep { !(BOM::Config::CurrencyConfig::is_valid_crypto_currency($_) && BOM::Config::CurrencyConfig::is_crypto_currency_suspended($_)) }
            LandingCompany::Registry->new()->all_currencies
    };
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

sub _build_all_client_dbs {
    my $clients_dbs       = [];
    my @all_brokers_codes = LandingCompany::Registry::all_broker_codes();
    my %visited_brokers;
    @visited_brokers{@all_brokers_codes} = ();

    for my $broker (@all_brokers_codes) {
        # Here we want to get unique clientdbs of all brokers
        # There might be more than one broker on a client db
        next unless exists $visited_brokers{$broker};
        next if LandingCompany::Registry->get_by_broker($broker)->is_virtual;

        my ($clientdb, $brokers_on_this_db);
        try {
            $clientdb = BOM::Database::ClientDB->new({
                    broker_code => $broker,
                    operation   => 'replica'
                }
                )->db
                || die "Client db creation returned undefined on $broker";
            $brokers_on_this_db =
                $clientdb->dbic->run(fixup => sub { $_->selectall_hashref('SELECT * FROM betonmarkets.broker_code', 'broker_code') });
        } catch {
            $log->errorf('Clientdb connection failed. Skipping %s: %s', $broker, $@);
            delete $visited_brokers{$broker};
            next;
        }
        delete @visited_brokers{keys %$brokers_on_this_db};
        push(@$clients_dbs, $clientdb);
    }
    return $clients_dbs;
}

=head2 open_bets_of

Accpets a broker name and returns all open bets on the broker's clientdb

=cut

sub open_bets_of {
    my ($self, $client_db) = @_;
    my $query  = q{ SELECT * FROM get_live_open_bets() };
    my $result = $client_db->dbic->run(fixup => sub { $_->selectall_hashref($query, 'id') });
    return $result;
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
