package BOM::Database::Model::Account;

use Moose;
use BOM::Database::AutoGenerated::Rose::Account;
extends 'BOM::Database::Model::Base';

use BOM::Database::Rose::DB::Relationships;    # make sure our table fixes are applied

has 'account_record' => (
    is      => 'rw',
    isa     => 'BOM::Database::AutoGenerated::Rose::Account',
    lazy    => 1,
    builder => '_build_account_record',
    handles => [BOM::Database::AutoGenerated::Rose::Account->meta->column_names],
);

sub _build_account_record {
    my $self = shift;
    return $self->_initialize_data_access_object('BOM::Database::AutoGenerated::Rose::Account',
        $self->_extract_related_attributes_for_account_class_hashref());
}

sub _extract_related_attributes_for_account_class_hashref {
    my $self = shift;

    my $result = $self->_extract_related_attributes_for_class_based_on_table_definition_hashref('BOM::Database::AutoGenerated::Rose::Account');

    if ($self->data_object_params and exists $self->data_object_params->{'account_id'}) {
        $result->{'id'} = $self->data_object_params->{'account_id'};
    }

    return $result;
}

sub save {
    my $self = shift;
    my $args = shift;

    return $self->_save_orm_object({'record' => $self->account_record});
}

# We need to ignore (ProhibitBuiltinHomonyms) for this specific method which
# basically overrides delete method of Rose::DB::Object and we can't help to
# just ignore perl ciritic for this line
#sub delete    ## no critic (ProhibitBuiltinHomonyms)
#{
#    my $self = shift;
#    my $args = shift;
#
#    return $self->_delete_orm_object({'record' => $self->account_record});
#}

sub load {
    my $self = shift;
    my $args = shift;

    return $self->_load_orm_object({
            'record'      => $self->account_record,
            'load_params' => $args->{'load_params'}});

}

sub class_orm_record {
    my $self = shift;

    return $self->account_record;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
