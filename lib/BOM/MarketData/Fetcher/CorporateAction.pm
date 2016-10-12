package BOM::MarketData::Fetcher::CorporateAction;

=head1 NAME

BOM::MarketData::Fetcher::CorporateAction

=head1 DESCRIPTION

An interface to fetch corporate action data from Chronicle

=cut

use Moose;
use Quant::Framework::CorporateAction;
use Quant::Framework::StorageAccessor;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);

=head2 get_underlyings_with_corporate_action

Returns a hash reference of underlyings which has corporate actions (in bloomberg format)

=cut

sub get_underlyings_with_corporate_action {
    my $self = shift;

    my @stocks_list = create_underlying_db->get_symbols_for(
        market            => ['stocks'],
        contract_category => 'callput'
    );

    my $storage_accessor = Quant::Framework::StorageAccessor->new(
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
    );

    my %list;
    foreach my $underlying_symbol (@stocks_list) {
        my $corp = Quant::Framework::CorporateAction::load($storage_accessor, $underlying_symbol);
        next unless $corp;

        $list{$underlying_symbol} = $corp->actions;
    }

    return \%list;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
