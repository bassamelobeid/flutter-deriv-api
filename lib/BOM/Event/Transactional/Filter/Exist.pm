use Object::Pad;

class BOM::Event::Transactional::Filter::Exist;

has $property_name;
has $property_value;
has $key = 'exists';

=head2 BUILD

Constructor, takes Property and it's value from map.yml

=cut

=head2 new
=cut

BUILD {
    my %args = @_;
    $property_name  = $args{property};
    $property_value = $args{property_value};
}

=head2 parse

Check if a candidate's attributes matches with filter's criteria, mainly if it contains the $key filter
If $key found in the candidate's attributes, it'll create a filter with property and it's value.

=cut

method parse ($property_name, $property_value) {

    return if (ref $property_value ne 'HASH') || !defined $property_value->{$key};

    return BOM::Event::Transactional::Filter::Exist->new(
        property       => $property_name,
        property_value => $property_value->{$key});
}

=head2 apply

Checks wether the event properties contains this filter property,
And apply the filter criteria on the event's property value with respect to referenced value.

=cut

method apply ($props) {
    my $event_value = $props->{$property_name};
    return ($property_value && defined $event_value) || (!$property_value && (!defined $event_value));
}

1;
