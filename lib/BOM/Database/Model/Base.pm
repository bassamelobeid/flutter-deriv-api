package BOM::Database::Model::Base;

use Moose;
use Rose::DB::Object;
use Rose::DB::Object::Manager;
use YAML::XS;

has 'record' => (
    is  => 'rw',
    isa => 'Maybe[Rose::DB::Object]',
);

has 'db' => (
    is  => 'rw',
    isa => 'Maybe[Rose::DB]',
);

has 'data_object_params' => (
    is        => 'rw',
    isa       => 'Maybe[HashRef]',
    predicate => 'is_data_object_params_initializied',
);

sub BUILD {
    my $self = shift;

    $self->_initialize_data_access_object('Rose::DB::Object',
        $self->_extract_related_attributes_for_class_based_on_table_definition_hashref('Rose::DB::Object'));

    return;
}

sub _initialize_data_access_object {
    my $self                                = shift;
    my $class_name                          = shift;
    my $filtered_data_object_params_hashref = shift;

    if ($filtered_data_object_params_hashref and ref $filtered_data_object_params_hashref ne 'HASH') {
        Carp::croak "[$0] Error::WRONG_HASHREF_PARAMETER: You must pass a hash reference or undef";
    }

    if ($filtered_data_object_params_hashref) {
        if ($self->db) {
            return $class_name->new(%{$filtered_data_object_params_hashref}, db => $self->db);
        } else {
            return $class_name->new(%{$filtered_data_object_params_hashref});
        }
    } else {
        if ($self->db) {
            return $class_name->new(db => $self->db);
        } else {
            return $class_name->new();
        }
    }

}

sub _extract_related_attributes_for_class_based_on_table_definition_hashref {
    my $self       = shift;
    my $class_name = shift;

    my $params        = $self->data_object_params;
    my @columns_array = $class_name->meta->column_names;

    return +{map { $_ => $params->{$_} } grep { exists $params->{$_} } @columns_array};
}

sub _save_orm_object {
    my $self   = shift;
    my $args   = shift;
    my $record = $args->{'record'};

    $record->db($self->db);
    return $record->save();
}

sub save {
    my $self = shift;

    return $self->_save_orm_object({'record' => $self->record});
}

sub _delete_orm_object {
    my $self   = shift;
    my $args   = shift;
    my $record = $args->{'record'};

    $record->db($self->db);
    return $record->delete();
}

# We need to ignore (ProhibitBuiltinHomonyms) for this specific method which
# basically overrides delete method of Rose::DB::Object and we can't help to
# just ignore perl ciritic for this line
sub delete    ## no critic (ProhibitBuiltinHomonyms)
{
    my $self = shift;

    return $self->_delete_orm_object({'record' => $self->record});
}

sub _load_orm_object {
    my $self   = shift;
    my $args   = shift;
    my $record = $args->{'record'};

    $record->db($self->db);
    return $record->load(%{$args->{'load_params'}});
}

sub load {
    my $self = shift;
    my $args = shift;

    return $self->_load_orm_object({
            'record'      => $self->record,
            'load_params' => $args->{'load_params'}});
}

sub class_orm_record {
    my $self = shift;

    return $self->record;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=pod

=head1 NAME

Model::Base

=head1 SYNOPSIS

 my $x = BOM::Database::Model::Base->new({data_object_params=>{id=>'1'}});
 $x->save;
 $x->load;
 $x->record->price('2');
 $x->save;
 $x->delete;

=head1 DESCRIPTION

 This simple module will be the parent of all model classes that aggregate other model classes.

 BUILD, save, load and delete methods can/must be overriden but all private methods must remain untouched.

 This class has a unit test that will use SQLite engine as it has no dependency on our data model and acts more as
 a guide line to create other classes and provide basic functionality for its children.

 NOTICE: $class_name->method is not a good practice and should not be used in the children of this class that will be heavily maintained.
 It was used jsut because it was the only way that I found to keep the design, not the code, clean.

=over 4


=item B<BUILDARGS>

 This method can be use to set a default value to some parameters.
 For example if we are initiating an object from BOM::Database::Model::AccountTransfer class,
 payment_type_code and payment_gateway_code are known. So even if those are not
 passes in the code we must set them here before initiating the code

=item B<new>

 data_object_params and db parameters can be sent to initiate the ORM data access object.

 Children of this class must also try to initialize their aggregate Models by passing these parameters.

 db, is a Rose::DB object

 data_object_params is a hashref that will is meaningful for Rose::DB::Object.

 For Rose::DB and Rose::DB:Object refer to cpan documents

 BOM::Database::Model::Base->new({data_object_params=>{id=>'1'}, db=$db});

 Main function of this method is to instantiate the ORM Object Recrod of the class.
 Notice that this ORM Object wont be overriden in children. Because even though, for example,
 AccountTransfer model is inherited from Payment, in it is data part they are two different tables and must be dealt with separately.

=item B<save>

 This method will represent the sequence of save for parent and child and also will do the necessary
 changes, like getting the serial ID from parrent to be used in child.

=item B<load>

 This method will load the data access object of class ( record ), and also it will trigger the load method
 in its parrents.

 load_params, can be passed as a hash refernce and its values must be meaningful for Rose::DB::Object.

=item B<delete>

 The method to remove the record.


=item B<_extract_related_attributes_for_class_hashref>

 When we want to initialize the class like RubBet, not all parameters we send are related to rub_bet table that
 we can use to initialize the Rose Object of rub_bet.

 This method will get all the table fields from Rose generated classes and it will extract the related fields
 from "data_object_params" to initialize the Rose object

 If there is something speciall about the attributes we can change the result afterwarrd.

 for example in Payment model this is necessary,
    if (defined $self->data_object_params and exists $self->data_object_params->{'payment_id'})
    {
        $result->{'id'} = $self->data_object_params->{'payment_id'};
    }

=item B<class_orm_record>

 This method will return the default ORM object of class.

 For example in BOM::Database::Model::Account it is an account_record that is a class of BOM::Database::AutoGenerated::Rose::Accont. So it returns $self->account_record.

 It will be used in those situations that we are dealing with general operation on a set of Models regardless of their specific type.
 For example working on Internal Transfer method in a helper class.


=back


=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut

