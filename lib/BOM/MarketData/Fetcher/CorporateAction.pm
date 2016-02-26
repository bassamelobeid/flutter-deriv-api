package BOM::MarketData::Fetcher::CorporateAction;

=head1 NAME

BOM::MarketData::Fetcher::CorporateAction

=head1 DESCRIPTION

An interface to fetch corporate action data from Chronicle

=cut

use Moose;
use Quant::Framework::CorporateAction;
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
        my $corp = Quant::Framework::CorporateAction->new(
            symbol           => $underlying_symbol,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());
        $list{$underlying_symbol} = $corp->actions if %{$corp->actions};
    }

    return \%list;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
