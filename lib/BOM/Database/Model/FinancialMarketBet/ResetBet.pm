package BOM::Database::Model::FinancialMarketBet::ResetBet;

use Moose;
use BOM::Database::Model::Constants;
use BOM::Database::AutoGenerated::Rose::ResetBet;
extends 'BOM::Database::Model::FinancialMarketBetOpen';

has 'reset_bet_record' => (
    is      => 'rw',
    isa     => 'BOM::Database::AutoGenerated::Rose::ResetBet',
    lazy    => 1,
    builder => '_build_reset_bet_record',
    handles => [BOM::Database::AutoGenerated::Rose::ResetBet->meta->column_names],
);

sub _build_reset_bet_record {
    my $self = shift;

    if ($self->financial_market_bet_open_record->can('reset_bet') and $self->financial_market_bet_open_record->reset_bet) {
        return $self->financial_market_bet_open_record->reset_bet;
    } else {
        return $self->_initialize_data_access_object('BOM::Database::AutoGenerated::Rose::ResetBet',
            $self->_extract_related_attributes_for_reset_class_hashref());
    }
}

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    # http://search.cpan.org/~doy/Moose-1.08/lib/Moose/Cookbook/Basics/Recipe10.pod
    # Because parent does not need to know about children, we will set two parameters by default here.
    if (@_ == 1 && ref $_[0]) {
        my $params = $_[0];

        if (exists $params->{'data_object_params'}) {
            if (exists $params->{'data_object_params'}->{'bet_class'}
                and $params->{'data_object_params'}->{'bet_class'} ne $BOM::Database::Model::Constants::BET_CLASS_RESET_BET)
            {
                Carp::croak "Error::WRONG_BET_CLASS [$0] bet_class for this class is wrong. However it can be set by default if it is not passed";
            }

            $params->{'data_object_params'}->{'bet_class'} = $BOM::Database::Model::Constants::BET_CLASS_RESET_BET;
        }
        return $class->$orig(@_);
    } else {
        return $class->$orig;
    }
};

sub _extract_related_attributes_for_reset_class_hashref {
    my $self = shift;

    my $result = $self->_extract_related_attributes_for_class_based_on_table_definition_hashref('BOM::Database::AutoGenerated::Rose::ResetBet');

    return $result;
}

sub save {
    my $self = shift;
    my $args = shift;

    $self->SUPER::save($args);
    $self->reset_bet_record->financial_market_bet_id($self->financial_market_bet_open_record->id);

    return $self->_save_orm_object({'record' => $self->reset_bet_record});
}

sub load {
    my $self = shift;
    my $args = shift;

    $self->SUPER::load($args);
    return $self->_load_orm_object({
            'record'      => $self->reset_bet_record,
            'load_params' => $args->{'load_params'}});
}

sub class_orm_record {
    my $self = shift;

    return $self->reset_bet_record;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=pod

=head1 NAME

BOM::Database::Model::FinancialMarketBet::ResetBet

=head1 SYNOPSIS

 my $payment_fee = BOM::Database::Model::FinancialMarketBet::ResetBet->new(
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

This class will encapsulate common characteristics attributes.

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut
