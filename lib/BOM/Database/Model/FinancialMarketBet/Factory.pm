package BOM::Database::Model::FinancialMarketBet::Factory;

use strict;
use warnings;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::FinancialMarketBet::LegacyBet;
use BOM::Database::Model::FinancialMarketBet::RangeBet;
use BOM::Database::Model::FinancialMarketBet::TouchBet;
use BOM::Database::Model::FinancialMarketBet::DigitBet;
use Carp;

=head1 NAME

BOM::Database::Model::FinancialMarketBet::Factory

=head1 SYNOPSYS

    my $bet = BOM::Database::Model::FinancialMarketBet::Factory->get(
        bet_id => $bet_id,
        db     => $db,
    );

=head1 DESCRIPTION

This class allows you to construct FinancialMarketBet object of right class.

=head1 METHODS

=cut

my %class_mapper = (
    higher_lower_bet => 'BOM::Database::Model::FinancialMarketBet::HigherLowerBet',
    legacy_bet       => 'BOM::Database::Model::FinancialMarketBet::LegacyBet',
    range_bet        => 'BOM::Database::Model::FinancialMarketBet::RangeBet',
    touch_bet        => 'BOM::Database::Model::FinancialMarketBet::TouchBet',
    digit_bet        => 'BOM::Database::Model::FinancialMarketBet::DigitBet',
);

=head2 $class->get(%params)

Return object of some subclass of BOM::Database::Model::FinancialMarketBet, depending
on the type of given bet. Accepts following parameters:

=over 4

=item bet_id

ID of the bet in financial_market_bet table

=item fmb_record

BOM::Database::AutoGenerated::Rose::FinancialMarketBet object for the bet

=item db

db

=back

=cut

sub get {
    my (undef, %params) = @_;

    $params{fmb_record} = $params{financial_market_bet_record} if $params{financial_market_bet_record};

    unless ($params{fmb_record}) {
        my $fmb = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->new(
            id => $params{bet_id},
            db => $params{db},
        );
        $fmb->load or croak "Can't load record for bet_id ``$params{bet_id}''";
        $params{fmb_record} = $fmb;
    }
    my $bet_class = $class_mapper{$params{fmb_record}->bet_class}
        or croak "Unknown bet_class: ", $params{fmb_record}->bet_class;
    return $bet_class->new({
        financial_market_bet_record => $params{fmb_record},
        db                          => $params{db},
    });
}

1;

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

