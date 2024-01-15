use Object::Pad;

class BOM::Event::Transactional::Mapper;

=head1 NAME

BOM::Event::Transactional::Mapper

=head1 SYNOPSIS

    use BOM::Event::Transactional::Mapper;
    my $mapper = BOM::Event::Transactional::Mapper->new;
    $mapper->load;
    my $event = $mapper->get_event($args);
    unless($event){
        die 'No mapped event found';
    }

=head1 DESCRIPTION

The Transactional events mapper, responsible for getting the transactional trigger name based on an emitted event and it's properties.

=cut

=head2 new

Parameterless constructor

=cut

use strict;
use warnings;
use YAML::XS;
use BOM::Event::Transactional::Filter::Equal;
use BOM::Event::Transactional::Filter::Contain;
use BOM::Event::Transactional::Filter::NotContain;
use BOM::Event::Transactional::Filter::Exist;

use constant CONFIG_PATH => "/home/git/regentmarkets/bom-events/config/transactional/";

field $map;
field @filters = (
    BOM::Event::Transactional::Filter::Equal->new, BOM::Event::Transactional::Filter::Contain->new,
    BOM::Event::Transactional::Filter::Exist->new, BOM::Event::Transactional::Filter::NotContain->new
);

=head2 load

Loads the `map.yml` from CONFIG_PATH, parse it's content and create a $map of event's filters.

=cut

method load {
    STDOUT->autoflush(1);
    my $cfg = YAML::XS::LoadFile(CONFIG_PATH . 'map.yml');
    for my $event (keys $cfg->%*) {
        $map->{$event} = [];
        for my $option ($cfg->{$event}->@*) {
            my $option_name    = (keys $option->%*)[0];
            my $option_value   = $option->{$option_name};
            my @parsed_filters = ();
            for my $property (keys $option_value->%*) {
                for my $filter (@filters) {
                    my $parsed = $filter->parse($property, $option_value->{$property});
                    push @parsed_filters, $parsed if $parsed;
                }
            }
            die "Transactional event with no conditions $option_name" unless scalar(@parsed_filters);
            push $map->{$event}->@*, {$option_name => \@parsed_filters};
        }
    }

    return $map;
}

=head2 get_event

Apply the filters of all transactional events mapped to an original event properties. the first one passes will be returned

=over 4

=item C<event> the original event name

=item C<properties> event properties to validate the filters against

=back

Returns the mapped transactional event on success and empty string if no match found.

=cut

method get_event ($args) {
    my $original_event = $args->{event};
    my $ev             = $map->{$original_event};
    return $original_event unless $ev;    #event is not conditional - no record found return original event.

    for my $candidate ($ev->@*) {
        my $candidate_event = (keys $candidate->%*)[0];
        return $candidate_event if $self->apply_filters($candidate->{$candidate_event}, $args->{properties});
    }
    return '';
}

=head2 apply_filters

Loop through all filters of a candidate transactional event and match the values against the originalevent properties.

=over 4

=item C<candidate> the transactional event candidate map entry which contains the filters.

=item C<properties> event properties to validate the filters against.

=back

If all filters pass return true otherwise return false;

=cut

method apply_filters ($candidate, $props) {

    for my $filter ($candidate->@*) {
        return unless ($filter->apply($props));
    }

    return 1;
}

1;
