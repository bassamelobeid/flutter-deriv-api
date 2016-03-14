package BOM::Market;

=head1 NAME

BOM::Market

=head1 DESCRIPTION

The representation of a market within our system

my $forex = BOM::Market->new({name => 'forex'});

=cut

use Moose;

use BOM::Platform::Runtime;
use BOM::Market::Markups;
use BOM::Market::Types;
use BOM::Platform::Context qw(request localize);
use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;

use List::Util qw(first);
use JSON qw( from_json );

=head1 ATTRIBUTES

=head2 name

Name of the market

=cut

has 'name' => (
    is       => 'ro',
    required => 1,
);

=head2 suspicious_move

Allowed percentage of spot price move over one day.

=cut

has suspicious_move => (
    is => 'ro',
);

=head2 outlier_tick

Allowed percentage move between consecutive ticks

=cut

has outlier_tick => (
    is => 'ro',
);

=head2 outlier_tick

Allowed percentage move between consecutive ticks when is crosses weekend/holiday

=cut

has weekend_outlier_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_weekend_outlier_tick {
    return shift->outlier_tick;
}

has integer_number_of_day => (
    is => 'ro',
    default => 0,
);

=head2 display_current_spot

A Boolean that determines if we are allowed to show current spot of this market to user

=cut

has display_current_spot => (
    is      => 'ro',
    default => 0,
);

=head2 display_name

The name of the market to be displayed

=cut

has 'display_name' => (
    is => 'ro',
);

=head2 explanation

Explanation of what this market is

=cut

has 'explanation' => (
    is => 'ro',
);

=head2 volatility_surface_type
Type of surface this financial market should have.
=cut

has volatility_surface_type => (
    is      => 'ro',
    default => '',
);

=head2 markups

All the markups used for this market as I<BOM::Market::Markups> object.

=cut

has 'markups' => (
    is      => 'ro',
    isa     => 'bom_market_markups',
    coerce  => 1,
    default => sub { BOM::Market::Markups->new(); });

=head2 generation_interval

How often we generate ticks, if a generated feed.

=cut

has generation_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    coerce  => 1,
    default => 0,
);

=head2 reduced_display_decimals

Has display decimals reduced by 1

=cut

has 'reduced_display_decimals' => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 asset_type

Represents the default asset_type for the market, can be (currency, index, asset).

=cut

has 'asset_type' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'asset',
);

=head2 vol_cut_off

Represents the vol_cut_off for the market, 
    default - represents market close
    NY1000 - represents a cutoff time of 'NY 11:00'

=cut

has 'vol_cut_off' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'Default',
);

=head2 foreign_bs_probability

Should foreign_bs_probability be used on this market

=cut

has 'foreign_bs_probability' => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 absolute_barrier_multiplier

Should barrier multiplier be applied for absolute barried on this market

=cut

has 'absolute_barrier_multiplier' => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 affected_by_corporate_actions

Should this financial market be affected by corporate actions

=cut

has affected_by_corporate_actions => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 prefer_discrete_dividend

Should this financial market use discrete dividend

=cut

has prefer_discrete_dividend => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 equity

Is this an equity

=cut

has 'equity' => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 eod_blackout_expiry

How close is too close to close for bet expiry?

=cut

has 'eod_blackout_expiry' => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '1m',
    coerce  => 1,
);

=head2 eod_blackout_start

How close is too close to close for bet start?

=cut

has 'eod_blackout_start' => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '0m',
    coerce  => 1,
);

=head2 sod_blackout_start

How close is too close to open for bet start?

=cut

has sod_blackout_start => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '10m',
    coerce  => 1,
);

=head2 intradays_must_be_same_day

Can any submarket of this be allowed to have intradays which cross days?

=cut

has intradays_must_be_same_day => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

=head2 max_suspend_trading_feed_delay

How long before we think the feed is down?

=cut

has max_suspend_trading_feed_delay => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '1m',
    coerce  => 1,
);

=head2 max_failover_feed_delay

How long before we switch to secondary feed provider?

=cut

has max_failover_feed_delay => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '2m',
    coerce  => 1,
);

=head2 display_order

The order with which this market has to be displayed

=cut

has 'display_order' => (
    is  => 'ro',
    isa => 'Int',
);

=head1 METHODS
=head2 translated_display_name

The display name after translating to the language provided.

=cut

sub translated_display_name {
    my $self = shift;

    return BOM::Platform::Context::localize($self->display_name);
}

has '_recheck_appconfig' => (
    is      => 'rw',
    default => sub { return time; },
);

=head2 disabled

Is this market disabled 

=cut

my $appconfig_attrs = [qw(disabled disable_iv)];
has $appconfig_attrs => (
    is         => 'ro',
    lazy_build => 1,
);

before $appconfig_attrs => sub {
    my $self = shift;

    my $now = time;
    if ($now >= $self->_recheck_appconfig) {
        $self->_recheck_appconfig($now + 23);
        foreach my $attr (@{$appconfig_attrs}) {
            my $clearer = 'clear_' . $attr;
            $self->$clearer;
        }
    }

};

sub _build_disabled {
    my $self = shift;
    my $disabled;

    my $disabled_markets = BOM::Platform::Runtime->instance->app_config->quants->markets->disabled;
    return (grep { $self->name eq $_ } @$disabled_markets);
}

=head2 disable_iv

Is iv disabled on this market

=cut

sub _build_disable_iv {
    my $self       = shift;
    my $disable_iv = BOM::Platform::Runtime->instance->app_config->quants->markets->disable_iv;
    return (grep { $self->name eq $_ } @$disable_iv);
}

=head2 deep_otm_threshold

Threshold for ask price value to which deep_otm contracts will be
pushed. For deep_itm contracts with ask price greater than
1 - deep_otm_threshold, it will be pushed to full payout

=cut

has deep_otm_threshold => (
    is      => 'ro',
    isa     => 'Num',
    default => 0.10,
);

=head2 providers

A list of feed providers for this market in the order of priority.

=cut

has 'providers' => (
    is      => 'ro',
    default => sub { [] },
);

=head2 license

The license we have for this feed.

=cut

has 'license' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'daily',
);

has 'official_ohlc' => (
    is  => 'ro',
    isa => 'Bool',
);

has spread_divisor => (
    is      => 'ro',
    default => 1,
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
