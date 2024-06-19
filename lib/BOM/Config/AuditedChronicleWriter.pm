package BOM::Config::AuditedChronicleWriter;

=head1 NAME

BOM::Config::AuditedChronicleWriter - A sublcass of Data::Chronicle::Writer to inject staff name data.

=head1 DESCRIPTION

Can be used by dynamic settings writer, will add the given staff name to the json stored in chrnicle db.

=cut

use Data::Chronicle::Writer;
use JSON::MaybeXS;
use Moose;

extends "Data::Chronicle::Writer";

has 'staff' => (
    isa => 'Str',
    is  => 'ro',
);

around '_archive' => sub {
    my $orig = shift;
    my $self = shift;
    my ($category, $name, $value, $rec_date) = @_;
    my $json = decode_json($value);

    $json->{staff} = $self->staff;

    $value = encode_json($json);

    return $self->$orig($category, $name, $value, $rec_date);
};

no Moose;

__PACKAGE__->meta->make_immutable;

1;
