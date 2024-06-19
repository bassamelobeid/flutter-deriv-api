package BOM::MT5::Script::AssetListing;
use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

MT5::Deriv::Scripts::AssetListing - fetches asset listing from MT5 groups T5 webapi and saves them in redis database.

=head1 SYNOPSIS

 use IO::Async::Loop;
 use MT5::Deriv::Scripts::AssetListing;


my $asset_listing= MT5::Deriv::Scripts::AssetListing->new()
$loop->add($asset_listing);

$config->run()->get();

=cut

use Future::AsyncAwait;
use Net::Async::Redis;
use Syntax::Keyword::Try;
use JSON::MaybeXS          qw(encode_json);
use BOM::Platform::Context qw (localize request);
use JSON::MaybeUTF8        qw(encode_json_utf8);
use Data::Dumper;
use YAML::XS qw(LoadFile);
use Date::Utility;
use Log::Any qw($log), formatter => sub {
    my ($cat, $lvl, @args) = @_;
    # Note : String::Flogger doesn't work
    Time::Moment->now . ' ' . sprintf($args[0], @args[1 .. $#args]);
};
use DataDog::DogStatsd::Helper qw/stats_inc/;
use BOM::MT5::User::Async;
use BOM::Config;
use constant MTR_PREFIX            => 'MTR';
use constant MAX_RETRY_COUNT       => 5;
use constant MT5_MIDCACHE          => 'MT5::MIDCACHE::';
use constant MT5_MIDCACHE_TTL_SECS => 86400;
use constant DEFAULT_RANKING       => 10000;
use constant UPDATE_INTERVAL_SECS  => 10;
use constant MT5_MARKET_MAPPER => {
    'Crypto'             => 'cryptocurrency',
    'Conversions'        => 'cryptocurrency',
    'Crypto_MF'          => 'cryptocurrency',
    'Forex Minor'        => 'forex',
    'Forex'              => 'forex',
    'Equities'           => 'stocks',
    'Energies'           => 'commodities',
    'Forex Micro'        => 'forex',
    'Range Break'        => 'derived',
    'Volatility Indices' => 'derived',
    'Derived Indices'    => 'derived',
    'Basket Indices'     => 'derived',
    'Forex_IV'           => 'forex',
    'Stock Indices'      => 'indices',
    'CFDIndices'         => 'indices',
    'SmartFX Indices'    => 'derived',
    'Crash Boom Indices' => 'derived',
    'Metals'             => 'commodities',
    'Step Indices'       => 'derived',
    'Jump Indices'       => 'derived',
    'Forex Major'        => 'forex',
    'Forex_III'          => 'forex',
    'Forex_II'           => 'forex',
};

use constant {
    MT5_PLATFORM                => 'mt5',
    MT5_REGIONS                 => ['eu',    'row'],
    MT5_ASSET_LISTING_TYPES     => ['brief', 'full'],
    ASSET_LISTING_STREAM_PREFIX => 'asset_listing'
};

use Date::Utility;

=head2 new

Create new instance

=over 4

=back

=cut

sub new {
    my ($class, %args) = @_;

    die 'mt5_config is required'   unless $args{mt5_config};
    die 'redis_config is required' unless $args{redis_config};

    $args{server_type}          //= 'real';
    $args{request_timeout}      //= 60;
    $args{connection_limit}     //= 30000;
    $args{use_proxy}            //= 0;
    $args{symbol_info_cache}    //= {};
    $args{update_interval_secs} //= UPDATE_INTERVAL_SECS;

    return bless \%args, $class;
}

=head2 update_interval_secs

Update interval of asset prices

=cut

sub update_interval_secs { shift->{update_interval_secs} }

=head2 symbol_info_cache

The symbol cache that holds symbol information

=cut

sub symbol_info_cache { shift->{symbol_info_cache} }

=head2 get_asset_listing_stream_channel

Return the stream channel for asset_listing 

=over 4

=item * platform - CFD platform, e.g. mt5

=item * region - eu or row

=item * type - brief or full

=back

=cut

sub get_asset_listing_stream_channel {

    my ($self, $platform, $region, $type) = @_;

    return ASSET_LISTING_STREAM_PREFIX . "::" . join("_", ($platform, $region, $type));

}

=head2 publish_asset_listing_channels

Publish updates to assets listing stream channels

=over 4

=back

=cut

async sub publish_asset_listing_channels {

    my ($self, $asset_listing_results) = @_;

    for my $region (MT5_REGIONS->@*) {
        for my $asset_listing_type (MT5_ASSET_LISTING_TYPES->@*) {
            my $channel = $self->get_asset_listing_stream_channel(MT5_PLATFORM, $region, $asset_listing_type);

            my @res  = ();
            my $resp = {};

            for my $asset ($asset_listing_results->@*) {

                my @tokens              = split(",", $asset->{availability});
                my %region_availability = map { $_ => 1 } @tokens;
                next unless $region_availability{$region};
                next if $asset_listing_type eq 'brief' and $asset->{display_order} == 10000;
                my %new_asset = map { lc $_ => $asset->{$_} } keys $asset->%*;
                delete $new_asset{availability};
                push @res, \%new_asset;
            }

            $resp->{mt5} = {assets => \@res};

            await $self->{redis}->publish($channel, encode_json_utf8($resp));

        }
    }
}

=head2 run

Runs the asset listing script

=over 4

=item * C<self> - self BOM::MT5::Script::AssetListing object

=back

=cut

async sub run {

    my $self = shift;

    my $assets_config       = BOM::Config::mt5_assets_config();
    my $webapi_config       = BOM::Config::mt5_webapi_config();
    my $mt5_symbols_mapping = LoadFile('/home/git/regentmarkets/bom-config/share/mt5-symbols.yml');
    my @mt5_groups          = ('real\p01_ts01\synthetic\bvi_std-hr_usd', 'real\p01_ts01\financial\bvi_std-hr_usd');
    $log->infof("Asset Listing script started");

    while (1) {

        my @results;
        $log->infof("Start asset listing update with %s", scalar(@results));

        for my $mt5_group (@mt5_groups) {

            $log->infof("Start asset listing update with group %s", $mt5_group);

            my $group_symbols = await $self->_get_group_symbols($mt5_group);
            my $manager_login = MTR_PREFIX . $webapi_config->{real}->{p01_ts01}->{manager}->{login};
            for my $group_symbol ($group_symbols->@*) {

                my @tokens      = split(/\\/, $group_symbol->{path});
                my $market      = $tokens[0];
                my $symbol_only = $tokens[-1];

                (await $self->_get_symbol_info($manager_login, $mt5_group, $symbol_only, $market))
                    unless $self->symbol_info_cache->{$mt5_group}->{$symbol_only};

            }

            my @symbols_list = keys $self->symbol_info_cache->{$mt5_group}->%*;
            my $symbol_str   = join(",", sort @symbols_list);
            stats_inc('mt5.asset_listing.symbols', {tags => ['symbols_list:' . $symbol_str, 'mt5_group:' . $mt5_group]});
            my $tick_last         = await $self->_get_last_ticks_for_group($manager_login, $symbol_str, $mt5_group);
            my $next_start_of_day = Date::Utility->new->plus_time_interval('1d')->truncate_to_day->epoch;

            for my $tick_detail ($tick_last->@*) {

                try {
                    my $bid         = $tick_detail->{bid};
                    my $ask         = $tick_detail->{ask};
                    my $symbol_name = $tick_detail->{symbol};
                    my $digits      = $self->symbol_info_cache->{$mt5_group}->{$symbol_name}{digits};
                    my $spread      = sprintf("%." . $digits . "f", $ask - $bid);
                    my $market      = MT5_MARKET_MAPPER->{$self->symbol_info_cache->{$mt5_group}->{$symbol_name}{market}};

                    my $symbol_asset_config = $assets_config->{$symbol_name};
                    my $display_order       = $symbol_asset_config ? $symbol_asset_config->{display_order} : DEFAULT_RANKING;
                    my $symbol_display_name = $symbol_asset_config ? $symbol_asset_config->{display_name}  : $symbol_name;
                    my $availability        = $symbol_asset_config ? $symbol_asset_config->{availability}  : ["eu", "row"];
                    my $shortcode           = $mt5_symbols_mapping->{$symbol_name} // $symbol_display_name;

                    my $cache_mid_price       = ($bid + $ask) / 2;
                    my $last_cached_mid_price = await $self->{redis}->get(MT5_MIDCACHE . $symbol_name);
                    my $day_percentage_change = '0.00%';

                    if ($last_cached_mid_price) {
                        # mid cached price not found
                        my $change_value = ($cache_mid_price - $last_cached_mid_price) * 100.0 / $last_cached_mid_price;
                        my $format       = $change_value > 0 ? "+%.2f" : "%.2f";
                        $day_percentage_change = sprintf($format, $change_value) . '%';
                    } else {
                        # Current epoch until the start of next day
                        my $expiry_ttl_till_start_next_day = $next_start_of_day - Date::Utility->new->epoch - 1;
                        (await $self->{redis}->set(MT5_MIDCACHE . $symbol_name, $cache_mid_price, 'EX', $expiry_ttl_till_start_next_day))
                            if $expiry_ttl_till_start_next_day > 0;
                        stats_inc('mt5.asset_listing.base_price_update',
                            {tags => ['symbol:' . $symbol_name, 'base_price:' . $cache_mid_price, "ttl_expiry:" . $expiry_ttl_till_start_next_day]});
                    }

                    $bid = sprintf("%." . $digits . "f", $bid);
                    $ask = sprintf("%." . $digits . "f", $ask);

                    my $asset_info = {
                        bid                   => $bid,
                        ask                   => $ask,
                        availability          => join(",", $availability->@*),
                        display_order         => $display_order,
                        spread                => $spread,
                        day_percentage_change => $day_percentage_change,
                        symbol                => $symbol_display_name,
                        shortcode             => $shortcode,
                        market                => $market
                    };

                    stats_inc('mt5.asset_listing.update', {tags => ['symbol:' . $symbol_name]});

                    push @results, $asset_info;

                } catch ($e) {

                    $log->errorf("Error in processing tick details - %s", $e);

                }

            }
        }

        await $self->{redis}->set('MT5::ASSETS', encode_json({assets => \@results}));

        await $self->publish_asset_listing_channels(\@results);

        $log->debugf('Updated %s assets', scalar(@results));

        stats_inc('mt5.asset_listing.assets_updated_count', {tags => ['count:' . scalar(@results)]});

        # Update every at every 10th second of the minute
        my $paused_interval = UPDATE_INTERVAL_SECS - Date::Utility->new->epoch % UPDATE_INTERVAL_SECS;
        (await $self->loop->delay_future(after => $paused_interval)) if $paused_interval;

    }

}

=head2 _get_last_ticks_for_group

Get last ticks for MT5 group

=over 4

=item * C<self> - self BOM::MT5::Script::AssetListing object

=item * C<mt5_group> -  MT5 group
 
=back

=cut

async sub _get_last_ticks_for_group {

    my ($self, $manager_login, $symbol_str, $mt5_group) = @_;
    my $tick_last;

    try {

        $tick_last = await BOM::MT5::User::Async::tick_last_group($manager_login, $symbol_str, $mt5_group);
    } catch ($e) {

        $log->errorf("Error in _get_last_ticks_for_group for %s , with symbols %s - %s", $mt5_group, $symbol_str, $e);

    }

    return $tick_last;

}

=head2 _get_group_symbols

Get group symbols

=over 4

=item * C<self> - self BOM::MT5::Script::AssetListing object

=item * C<mt5_group> -  MT5 group
 
=back

=cut

async sub _get_group_symbols {

    my ($self, $mt5_group) = @_;
    my @group_symbols;

    try {
        my $group_info = await BOM::MT5::User::Async::get_group($mt5_group);
        @group_symbols = $group_info->{symbols}->@*;

    } catch ($e) {
        $log->errorf("Error in _get_group_symbols %s", $e);
    }

    return \@group_symbols;

}

=head2 _get_symbol_info

Get symbol info

=over 4

=item * C<self> - self BOM::MT5::Script::AssetListing object

=item * C<manager_login> -  Manager Login account

=item * C<mt5_group> -  MT5 Group

=item * C<symbol_only> - Asset Symbol

=item * C<market> - Market 

=back

=cut

async sub _get_symbol_info {

    my ($self, $manager_login, $mt5_group, $symbol_only, $market) = @_;

    my $symbol_info;

    try {
        $symbol_info = await BOM::MT5::User::Async::get_symbol($manager_login, $symbol_only);

        $self->symbol_info_cache->{$mt5_group}->{$symbol_only} = {
            market => $market,
            digits => $symbol_info->{digits},
            point  => $symbol_info->{point}};

    } catch ($e) {
        $log->errorf("Error in _get_symbol_info %s", $e);
    }

    return $symbol_info;

}

=head2 _add_to_loop

Add to IO Async Loop

=over 4

=item * C<self> - self BOM::MT5::Script::AssetListing object

=back

=cut

sub _add_to_loop {
    my $self = shift;

    my $redis_config = LoadFile($self->{redis_config})->{write};
    my $redis        = Net::Async::Redis->new(
        uri  => "redis://$redis_config->{host}:$redis_config->{port}",
        auth => $redis_config->{password});

    $self->{redis} = $redis;
    $self->add_child($redis);

}

1;
