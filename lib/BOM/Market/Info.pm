package BOM::Market::Info;
use 5.010;
use Moose;



use BOM::Platform::Runtime;
use BOM::Market::Underlying;

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

has '_recheck_appconfig' => (
    is      => 'rw',
    default => sub { return time; },
);

my $appconfig_attrs = [qw(is_buying_suspended is_trading_suspended)];
has $appconfig_attrs => (
    is         => 'ro',
    lazy_build => 1,
);

before $appconfig_attrs => sub {
    my $self = shift;

    my $now = time;
    if ($now >= $self->_recheck_appconfig) {
        $self->_recheck_appconfig($now + 19);
        foreach my $attr (@{$appconfig_attrs}) {
            my $clearer = 'clear_' . $attr;
            $self->$clearer;
        }
    }
};

=head2 is_buying_suspended

Has buying of this underlying been suspended?

=cut

sub _build_is_buying_suspended {
    my $self = shift;

    # Trade suspension implies buying suspension, as well.
    return (
        $self->is_trading_suspended
            or grep { $_ eq $self->underlying->symbol } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy}));
}

=head2 is_trading_suspended

Has all trading on this underlying been suspended?
Used in bom-rpc and bom (Contract)

=cut

sub _build_is_trading_suspended {
    my $self = shift;

    return (
               not keys %{$self->underlying->contracts}
            or $self->_market_disabled
            or grep { $_ eq $self->underlying->symbol } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades}));
}

sub _market_disabled {
    my $self = shift;

    my $disabled_markets = BOM::Platform::Runtime->instance->app_config->quants->markets->disabled;
    return (grep { $self->underlying->market->name eq $_ } @$disabled_markets);
}

1;
