package BOM::Database::DataMapper::MyAffiliates;

use Moose;
use BOM::Database::Model::Constants;

extends 'BOM::Database::DataMapper::Base';

=head1 METHODS

=over

=item get_clients_activity

get different factors of clients activity needed for myaffiliates pl reports.

=cut

sub get_clients_activity {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_activity($1, $2, $3, $4, $5)
    };

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{date}, $args->{only_authenticate} || 'false', $args->{broker_code}, $args->{include_apps}, $args->{exclude_apps});

            return $sth->fetchall_hashref('loginid');
        });
}

=item get_trading_activity

get client trading activity for particular date for myaffiliates turnover reports.

=cut

sub get_trading_activity {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_trading_activity($1, $2, $3)
    };

    return $dbic->run(
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{date}, $args->{include_apps}, $args->{exclude_apps});

            return $sth->fetchall_arrayref;
        });
}

=item get_multiplier_commission

get clients' multiplier contracts trading activity for particular date for myaffiliates reports.

=cut

sub get_multiplier_commission {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_multiplier_trading_activity($1, $2, $3)
    };

    return $dbic->run(
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{date}, $args->{include_apps}, $args->{exclude_apps});

            return $sth->fetchall_arrayref;
        });
}

=item get_contracts_with_spread_commission

get clients' trading activity for contracts with spread on a particular date used in myaffiliates reports.

=cut

sub get_contracts_with_spread_commission {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_with_spread_trading_activity($1, $2, $3, $4)
    };

    return $dbic->run(
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{bet_class}, $args->{date}, $args->{include_apps}, $args->{exclude_apps});

            return $sth->fetchall_arrayref;
        });
}

=item get_lookback_activity

get clients' lookback contracts trading activity for particular date for myaffiliates reports.

=cut

sub get_lookback_activity {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_lookback_turnover_commission($1, $2, $3)
    };

    return $dbic->run(
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{date}, $args->{include_apps}, $args->{exclude_apps});

            return $sth->fetchall_arrayref;
        });
}

=item get_monthly_exchange_rate

get average monthly exchnage rates for given currency against USD.

=cut

sub get_monthly_exchange_rate {
    my ($self, $args) = @_;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM data_collection.get_average_montly_exchange_rate_usd($1, $2, $3)
    };

    return $dbic->run(
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{source_currency}, $args->{month}, $args->{year});

            return $sth->fetchall_arrayref;
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

=back

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
