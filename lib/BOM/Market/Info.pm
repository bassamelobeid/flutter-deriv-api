package BOM::Market::Info;

use 5.010;
use Moose;

use BOM::Platform::Runtime;

=head1 NAME

BOM::Market::Info

=head1 DESCRIPTION

Provides access to some built-in settings and configurations about underlying.


my $underlying_info = BOM::Market::Info->new('frxEURUSD');

=cut

has underlying => (
    is       => 'ro',
    required => 1,
);

has combined_folder => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 combined_folder

Return the directory name where we keep our quotes.

=cut

# sooner or later this should go away... or at least be private.
sub _build_combined_folder {
    my $self              = shift;
    my $underlying_symbol = $self->underlying->system_symbol;
    my $market            = $self->underlying->market;

    if ($market->name eq 'config') {
        $underlying_symbol =~ s/^FRX/^frx/;
        return 'combined/' . $underlying_symbol . '/quant';
    }

# For not config/vols return combined. Feed is saved in combined/ (no subfolder)
    return 'combined';
}

=head2 fullfeed_file

Where do we find the fullfeed file for the provided date?  Second argument allows override of the 'combined' portion of the path.

=cut

sub fullfeed_file {
    my ($self, $date, $override_folder) = @_;

    if ($date =~ /^(\d\d?)\-(\w\w\w)\-(\d\d)$/) {
        $date = $1 . '-' . ucfirst(lc($2)) . '-' . $3;
    }    #convert 10-JAN-05 to 10-Jan-05
    else {
        die 'Bad date for fullfeed_file';
    }

    my $folder = $override_folder || $self->combined_folder;

    return
          BOM::Platform::Runtime->instance->app_config->system->directory->feed . '/'
        . $folder . '/'
        . $self->underlying->system_symbol . '/'
        . $date
        . ($override_folder ? "-fullfeed.csv" : ".fullfeed");
}

1;
