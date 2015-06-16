package BOM::Database::Model::FinancialMarketBet;

use Moose;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBet;

extends 'BOM::Database::Model::Base';

has 'financial_market_bet_record' => (
    is      => 'rw',
    isa     => 'BOM::Database::AutoGenerated::Rose::FinancialMarketBet',
    lazy    => 1,
    builder => '_build_financial_market_bet_record',
    handles => [BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->column_names],
);

has 'legacy_parameters' => (
    is      => 'rw',
    isa     => 'Maybe[HashRef]',
    lazy    => 1,
    builder => '_build_legacy_parameters',
);

sub _build_financial_market_bet_record {
    my $self = shift;

    return $self->_initialize_data_access_object('BOM::Database::AutoGenerated::Rose::FinancialMarketBet',
        $self->_extract_related_attributes_for_financial_market_bet_class_hashref());
}

sub BUILD {
    my $self = shift;
    my $args = shift;

    return;
}

sub _build_legacy_parameters {
    my $self = shift;

    if ($self->is_data_object_params_initializied) {
        my $legacy_parameters;
        my $data_object_params = $self->data_object_params;

        if (exists $data_object_params->{'transaction_time'}) {
            $legacy_parameters->{'transaction_time'} = $data_object_params->{'transaction_time'};
        }

        if (exists $data_object_params->{'staff_loginid'}) {
            $legacy_parameters->{'staff_loginid'} = $data_object_params->{'staff_loginid'};
        }

        if (defined $legacy_parameters) {
            return $self->legacy_parameters($legacy_parameters);
        }
    }
    return;
}

sub _extract_related_attributes_for_financial_market_bet_class_hashref {
    my $self = shift;

    my $result =
        $self->_extract_related_attributes_for_class_based_on_table_definition_hashref('BOM::Database::AutoGenerated::Rose::FinancialMarketBet');

    if ($self->is_data_object_params_initializied) {
        my $data_object_params = $self->data_object_params;

        if (exists $data_object_params->{'financial_market_bet_id'}) {
            $result->{'id'} = $data_object_params->{'financial_market_bet_id'};
        }
    }

    return $result;

}

sub save {
    my $self = shift;
    my $args = shift;

    $self->_save_orm_object({'record' => $self->financial_market_bet_record});

    # Unless if it dies in the process of save
    return 1;

}

sub load {
    my $self = shift;
    my $args = shift;

    my $result = $self->_load_orm_object({
            'record'      => $self->financial_market_bet_record,
            'load_params' => $args->{'load_params'}});

    return $result;

}

sub class_orm_record {
    my $self = shift;

    return $self->financial_market_bet_record;
}

no Moose;
__PACKAGE__->meta->make_immutable;

=pod

=head1 NAME

BOM::Database::Model::FinancialMarketBet

=head1 SYNOPSIS

 my $payment_fee = BOM::Database::Model::FinancialMarketBet->new(
    {
        'data_object_params'=>
        {
            'account_id' => $account->account_record->id,
            'price'=>10.2,
            ....
        },
        db=>$connection_builder->db
    },
 );

=head1 DESCRIPTION

This class will encapsualte common characteristics attributes.

=over 4

=item B<sell_bet>

 This subroutine will set the is_sold and sell_price for bet if we try to sell it.

=back

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut

1;
