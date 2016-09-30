package BOM::Market;

=head1 NAME

BOM::Market

=head1 DESCRIPTION

The representation of a market within our system

my $forex = BOM::Market->new({name => 'forex'});

=cut

use Moose;

use BOM::Market::Markups;

has 'name' => (
    is       => 'ro',
    required => 1,
);

has suspicious_move => (
    is => 'ro',
);

=head2 integer_barrier

Only allow integer barrier for this market. Default to false.

=cut

has [qw(integer_barrier)] => (
    is      => 'ro',
    default => 0,
);

=head2 display_current_spot

A Boolean that determines if we are allowed to show current spot of this market to user

=cut

has display_current_spot => (
    is      => 'ro',
    default => 0,
);

has 'display_name' => (
    is => 'ro',
);

has 'explanation' => (
    is => 'ro',
);

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

=head2 eod_blackout_start

How close is too close to close for bet start?

=head2 sod_blackout_start

How close is too close to open for bet start?

=cut

has [qw(eod_blackout_expiry eod_blackout_start sod_blackout_start)] => (
    is      => 'ro',
    default => undef,
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
    default => '5m',
    coerce  => 1,
);

=head2 display_order

The order with which this market has to be displayed

=cut

has 'display_order' => (
    is  => 'ro',
    isa => 'Int',
);

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

# if you did not define this, I assume you don't offer it.
has risk_profile => (
    is      => 'ro',
    default => 'no_business',
);

has base_commission => (
    is      => 'ro',
    default => 0.05,
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
