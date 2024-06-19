use Object::Pad;

class BOM::Event::Transactional::Filter::Contain;

use List::Util qw(any);

field $property_name;
field $property_value;
field $key = 'contains';

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
    return if (ref $property_value ne 'HASH') || !$property_value->{$key};

    return BOM::Event::Transactional::Filter::Contain->new(
        property       => $property_name,
        property_value => $property_value->{$key});
}

=head2 apply

Checks wether the event properties contains this filter property,
And apply the filter criteria on the event's property value with respect to referenced value.

=cut

method apply ($props) {
    my $event_values = (ref $props->{$property_name} eq 'ARRAY') ? $props->{$property_name} : [$props->{$property_name}];
    return unless defined $event_values;

    for my $event_value ($event_values->@*) {

        return 1 if $self->contains_value($event_value);
    }

    return 0;
}

=head2 contains_value

Checks wether the event property value contains the filter property value.

=cut

method contains_value ($event_value) {
    return unless defined $event_value;

    return any { $event_value =~ m/$_/i } @$property_value if (ref $property_value eq 'ARRAY');

    return $event_value =~ m/$property_value/i;
}

1;
