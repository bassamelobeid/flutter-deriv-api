package BOM::MarketData::Fetcher::CorporateAction;

=head1 NAME

BOM::MarketData::Fetcher::CorporateAction

=head1 DESCRIPTION

An interface to fetch corporate action data from couch

=cut

use Moose;
use BOM::MarketData::CorporateAction;
use BOM::Market::UnderlyingDB;

=head2 get_underlyings_with_corporate_action

Returns a hash reference of underlyings which has corporate actions

=cut

sub get_underlyings_with_corporate_action {
    my $self = shift;

    my @stocks_list = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['stocks'],
        contract_category => 'callput'
    );

    my %list;
    foreach my $underlying_symbol (@stocks_list) {
        my $corp = BOM::MarketData::CorporateAction->new(symbol => $underlying_symbol);
        $list{$underlying_symbol} = $corp->actions if %{$corp->actions};
    }

    return \%list;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
