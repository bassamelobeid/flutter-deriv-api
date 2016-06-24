package BOM::Product::Role::Reportable;

use Moose::Role;

use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Database::Model::Constants;
use BOM::System::Config;

my @bool_attrs = qw(is_intraday is_forward_starting is_atm_bet is_spread);

requires @bool_attrs;

sub _report_validation_stats {
    my ($self, $which, $valid) = @_;

    # This should all be fast, since everything should have been pre-computed.

    my $stats_name = 'pricing_validation.' . $which . '.';
    # These attempt to be close to the Transaction stats without compromising their value.
    # It may be worth adding a free-form 'source' identification, but I don't want to go
    # down that road just yet.
    my $tags = {
        tags => [
            'rmgenv:' . BOM::System::Config::env,
            'contract_class:' . $BOM::Database::Model::Constants::BET_TYPE_TO_CLASS_MAP->{$self->code},
            map { substr($_, 3) . ':' . ($self->$_ ? 'yes' : 'no') } (@bool_attrs)]};

    stats_inc($stats_name . 'attempt', $tags);
    if ($valid) {
        stats_inc($stats_name . 'success', $tags);
    } else {
        # We can be a tiny bit slower here as we're already reporting an error
        my $error = $self->primary_validation_error->message;
        $error =~ s/(?<=[^A-Z])([A-Z])/ $1/g;    # camelCase to words
        $error =~ s/\[[^\]]+\]//g;               # Bits between [] should be dynamic
        $error = join('_', split /\s+/, lc $error);
        push @{$tags->{tags}}, 'reason:' . $error;
        stats_inc($stats_name . 'failure', $tags);
    }

    return $valid;
}

1;
