package BOM::MT5::Script::LivePricing;
use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

MT5::Deriv::Scripts::LivePricing - listens to feed from MT5 listener and post them on firebase

=head1 SYNOPSIS

 use IO::Async::Loop;
 use MT5::Deriv::Scripts::LivePricing;


my $live_pricing= MT5::Deriv::Scripts::LivePricing->new()
$loop->add($live_pricing);

$config->run()->get();

=cut

use URI;
use Finance::Underlying;
use Format::Util::Numbers qw(roundnear);
use Data::Dump            qw(pp);
use Future::AsyncAwait;
use Net::Async::Redis;
use Net::Async::HTTP;
use Syntax::Keyword::Try;
use BOM::Platform::Context qw (localize);
use JSON::MaybeUTF8        qw(encode_json_utf8 decode_json_utf8);
use YAML::XS               qw(LoadFile);
use Log::Any               qw($log), formatter => sub {
    my ($cat, $lvl, @args) = @_;
    # Note : String::Flogger doesn't work
    Time::Moment->now . ' ' . sprintf($args[0], @args[1 .. $#args]);
};
use BOM::MT5::User::Async;
use BOM::Config;

=head2 DEFAULT_MAX_CONNECTION

Defaults to 10 connections to firebase, unless specified.

=head2 MTR_PREFIX

MTR string

=head2 SECONDS_IN_DAY

Represents the number of seconds in a day

=head2 MT5_MIDCACHE

Redis key prefix to cache daily mid price

=head2 MARKET_MAPPER

A hash reference to map market string from MT5 to its display name

=head2 MAPPER

A hash reference to map string to its abbreviation for cost optimisation on firebase

=cut

use constant DEFAULT_MAX_CONNECTION => 20;
use constant MTR_PREFIX             => 'MTR';
use constant SECONDS_IN_DAY         => 86400;
use constant MT5_MIDCACHE           => 'MT5::MIDCACHE::';
use constant MARKET_MAPPER => {
    'Crypto'              => 'cryptocurrency',
    'Crypto Crypto_cross' => 'cryptocurrency',
    'Forex Minor'         => 'forex',
    'Forex Micro'         => 'forex',
    'Forex Major'         => 'forex',
    'Forex Exotic'        => 'forex',
    'Forex'               => 'forex',
    'ETFs'                => 'etfs',
    'DEX Indices'         => 'derived',
    'Range Break'         => 'derived',
    'Volatility Indices'  => 'derived',
    'Derived Indices'     => 'derived',
    'Basket Indices'      => 'derived',
    'Crash Boom Indices'  => 'derived',
    'Step Indices'        => 'derived',
    'Jump Indices'        => 'derived',
    'Stock Indices'       => 'indices',
    'Equities US'         => 'stocks',
    'Equities Europe'     => 'stocks',
    'Energies'            => 'commodities',
    'Metals'              => 'commodities',
};

# this is purely for cost reduction.
use constant MAPPER => {
    market         => 'mkt',
    commodities    => 'com',
    derived        => 'der',
    cryptocurrency => 'cry',
    forex          => 'fx',
    indices        => 'ind',
    stocks         => 'stk',
    etfs           => 'etfs',
};

=head2 new

Create new instance

=over 4

=back

=cut

sub new {
    my ($class, %args) = @_;

    die 'mt5_config is required'        unless $args{mt5_config};
    die 'mt5_redis_config is required'  unless $args{mt5_redis_config};
    die 'feed_redis_config is required' unless $args{feed_redis_config};
    die 'firebase_config is required'   unless $args{firebase_config};

    $args{max_connection} //= DEFAULT_MAX_CONNECTION;

    return bless \%args, $class;
}

=head2 run

Runs the asset listing script

=over 4

=item * C<self> - self BOM::MT5::Script::LivePricing object

=back

=cut

async sub run {
    my $self = shift;

    await $self->initialise_config();

    $log->debug("Running live pricing");

    my @futures = ($self->update_price, $self->subscribe_for_tick, $self->reload_config,);

    await Future->wait_any(@futures);
}

=head2 subscribe_for_tick

Subscribes and process MT5 ticks.

=cut

async sub subscribe_for_tick {
    my $self = shift;

    my $feed_redis = $self->{feed_redis};

    await $feed_redis->connect->then(
        sub {
            $feed_redis->psubscribe('MT5::*');
        }
    )->then(
        sub {
            my ($sub) = @_;
            my $source = $sub->events->map('payload')->decode('json');
            $source->each(
                sub {
                    my $tick = shift;
                    $self->process_tick($tick)->retain;
                });
            $source->completed->on_fail(
                sub {
                    $log->debug("fail to process");
                });
        });
}

=head2 process_tick

Gathers all information related to a tick and saves it to a hash object. Information includes:

=over 4

=item * ask - ask price of an instrument

=item * bid = bid price of an instrument

=item * mid - spot price of an instrument (bid+ask)/2

=item * sprd - the difference between bid and ask

=item * mkt - market name

=item * code - symbol shortcode

=item * sym - symbol display name

=item * chng - daily percentage change

=item * reg - region (eu or row)

=back

=cut

async sub process_tick {
    my ($self, $tick) = @_;

    try {
        foreach my $region ($self->{_symbol_region}->{$tick->{symbol}}->@*) {
            my $conf = $self->{_config}->{$region}{$tick->{symbol}};
            # we are only supporting a short list of symbols defined in live_pricing_config in backofice.
            unless ($conf) {
                $log->debugf("Missing config for symbol: %s. Skipping...", $tick->{symbol});
                return;
            }

            $log->debugf("Ticks received: %s", pp($tick));

            my $prev_bid = $self->{_previous_tick}{$tick->{symbol}}{bid} // 0;
            my $prev_ask = $self->{_previous_tick}{$tick->{symbol}}{ask} // 0;
            if ($prev_bid == $tick->{bid} && $prev_ask == $tick->{ask}) {
                $log->debugf("Duplicate bid/ask for %s. Skipping...", $tick->{symbol});
                return;
            }

            my $new_bid    = $tick->{bid} - $conf->{point} * (($conf->{spread_diff} + 1) / 2 - $conf->{spread_diff_balance});
            my $new_ask    = $tick->{ask} + $conf->{point} * ($conf->{spread_diff} / 2 + $conf->{spread_diff_balance});
            my $new_mid    = ($new_ask + $new_bid) / 2;
            my $spread     = $new_ask - $new_bid;
            my $cached_mid = await $self->{mt5_redis}->get(MT5_MIDCACHE . $tick->{symbol});

            my $daily_percentage_change = defined $cached_mid ? ($new_mid - $cached_mid) / $cached_mid * 100 : 0;
            my $rounded_dpc             = roundnear(0.01, $daily_percentage_change);
            my $dpc_prefix              = $rounded_dpc < 0 ? '-' : $rounded_dpc > 0 ? '+' : '';
            my $formatted_dpc           = $dpc_prefix . abs($rounded_dpc) . '%';
            my $market                  = MARKET_MAPPER->{$conf->{market}};
            my $code                    = $tick->{symbol};
            $code =~ s/\s+/_/g;
            $code =~ s/\./_/g;

            unless ($market) {
                $log->debugf("Missing market grouping for: ", $conf->{market});
                return;
            }

            my $data = {
                ask  => Finance::Underlying->pipsized_value($new_ask, $conf->{point}) + 0,
                bid  => Finance::Underlying->pipsized_value($new_bid, $conf->{point}) + 0,
                mid  => Finance::Underlying->pipsized_value($new_mid, $conf->{point}) + 0,
                sprd => Finance::Underlying->pipsized_value($spread,  $conf->{point}) + 0,    # spread
                ord  => $conf->{display_order},                                               # display_order
                mkt  => $market,                                                              # market
                code => $code,                                                                # shortcode
                sym  => localize($conf->{display_name}),                                      # display symbol
                chng => $formatted_dpc,                                                       # day percentage change
                reg  => $region,                                                              #region
            };
            $self->{next_update}{$region}{$market}{$code} = $data;
            # signafies an update on market level
            $self->{next_update}{$region}{$market}{updated} = 1;

            # It's ok if we're setting this twice if symbol is valid for multiple region
            $self->{_previous_tick}{$tick->{symbol}} = $data;
        }
    } catch ($e) {
        $log->debugf("fail to process tick with %s", $e);
    }
}

=head2 update_price

Pushes data to firebase every second when there's update.

=cut

async sub update_price {
    my $self = shift;

    while (1) {
        # perform update
        my @futures;
        foreach my $region (keys $self->{next_update}->%*) {
            foreach my $market (keys $self->{next_update}->{$region}->%*) {
                if (delete $self->{next_update}{$region}{$market}{updated}) {
                    my $data   = $self->{next_update}->{$region}{$market};
                    my $target = [$region, qw(mkt), MAPPER->{$market}];
                    $log->debugf("refreshing firebase by target: %s, data: %s", pp($target), encode_json_utf8($data));
                    push @futures, $self->firebase_set($target, $data);
                }
            }
        }
        await Future->wait_all(@futures);
        my $t     = Time::HiRes::time;
        my $after = 1 - ($t - int($t));
        await $self->loop->delay_future(after => $after);
    }
}

=head2 firebase_set

Put feed value to firebase.

=over 4

=item * $target - path to update in array reference

=item * $data - feed data in hash reference.

=back

=cut

{
    my $cfg;

    async sub firebase_set {
        my ($self, $target, $data) = @_;

        $cfg //= LoadFile($self->{firebase_config});
        my $uri = URI->new($cfg->{host});
        $uri->path(join('/', $target->@*) . '.json');

        $log->debugf("Path %s", $uri->path);
        # Use predefined long-lived token from Firebase console,
        # can also use a service account but would take a bit of
        # extra setup and configuration (see git history for details
        # on how to make that work)
        $uri->query_param(auth => $cfg->{token});
        my $res = await $self->{ua}->PUT($uri, encode_json_utf8($data), content_type => 'application/json')->transform(
            done => sub {
                my ($resp) = @_;
                decode_json_utf8($resp->content);
            }
        )->else(
            sub {
                my ($err, $src, $resp, $req) = @_;
                if ($src eq 'http' and $req and $resp) {
                    $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
                } else {
                    $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
                }
                # We should just log it and move on. Since the prices are purely for display only, consistency is not required.
                Future->done(@_);
            });
        $log->debugf('JSON response: %s', pp($res));
    }
}

=head2 initialise_config

Initialise instrument configuration from MT5 settings.

=cut

async sub initialise_config {
    my $self = shift;

    try {
        # This will need to be configuration in the backoffice
        my $live_pricing = BOM::Config::Runtime->instance->app_config->quants->live_pricing_config;
        my $config;
        my $available_region;
        foreach my $region (qw(eu row)) {
            $log->debugf("initialising config for region: %s", $region);
            my $symbols_config = decode_json_utf8($live_pricing->$region->symbols // '[]');
            unless ($symbols_config->@*) {
                $log->debugf("Undefined symbols config for region: %s", $region);
                next;
            }

            foreach my $c ($symbols_config->@*) {
                my $mt5_group           = $c->{group};
                my $group_symbol_config = await $self->_get_group_symbol_config($mt5_group);
                foreach my $symbol_config ($c->{symbols}->@*) {
                    my $symbol = $symbol_config->{symbol};
                    unless (defined $group_symbol_config->{$symbol}) {
                        $log->debugf("group symbol config not found for group %s and %s", $mt5_group, $symbol);
                        next;
                    }
                    $config->{$region}{$symbol} //= {$group_symbol_config->{$symbol}->%*, $symbol_config->%*};
                    push $available_region->{$symbol}->@*, $region;
                }
            }
        }

        # init previous ticks
        $self->{_previous_tick} = {};
        $self->{_config}        = $config;
        $self->{_symbol_region} = $available_region;
    } catch ($e) {
        $log->warnf("failed to load config. Error: %s", pp($e));
    }

    return;
}

=head2 reload_config

A timer to reload instrument configuration every sunday.

=cut

async sub reload_config {
    my $self = shift;

    while (1) {
        $log->debug("Reload config in progress..");
        await $self->initialise_config();
        my $date = Date::Utility->today->plus_time_interval('1d');
        while ($date->day_of_week != 0) {
            $date = $date->plus_time_interval('1d');
        }
        $log->debugf("Next reload starting on %s ", $date->datetime);
        await $self->loop->delay_future(at => $date->epoch);
    }
}

=head2 _get_group_symbol_config

Get configuration to calculate spread for instruments.

=cut

async sub _get_group_symbol_config {
    my ($self, $mt5_group) = @_;

    my $manager_login = $self->_get_manager_for_group($mt5_group);

    unless ($manager_login) {
        $log->debugf("Undefined manager login for group %s", $mt5_group);
        return undef;
    }

    my $group_info = await BOM::MT5::User::Async::get_group($mt5_group);

    unless ($group_info->{symbols}) {
        $log->debugf("No symbols for group: %s", $mt5_group);
        return undef;
    }

    my $config;
    foreach my $symbol ($group_info->{symbols}->@*) {
        my @paths      = split /\\/, $symbol->{path};
        my $mt5_symbol = $paths[-1];

        my $conf = await BOM::MT5::User::Async::get_symbol($manager_login, $mt5_symbol);
        # we want to store the config in deriv symbol because ticks are streamed in deriv symbol
        $config->{$mt5_symbol} = {
            spread_diff         => $symbol->{spreadDiff},
            spread_diff_balance => $symbol->{spreadDiffBalance},
            point               => $conf->{point} + 0,             # remove trailing zero
        };
    }

    return $config;
}

=head2 _get_manager_for_group

Get MT5 manager id

=cut

{
    my $webapi_config;

    sub _get_manager_for_group {
        my ($self, $mt5_group) = @_;

        $webapi_config //= LoadFile($self->{mt5_config});
        my ($type, $server_id) = split /\\/, $mt5_group;
        my $login = $webapi_config->{$type}{$server_id}{manager}{login};

        return MTR_PREFIX . $login if $login;
        return undef;
    }
}

=head2 _add_to_loop

Add to IO Async Loop

=over 4

=item * C<self> - self BOM::MT5::Script::LivePricing object

=back

=cut

sub _add_to_loop {
    my $self = shift;

    my $mt5_redis_config = LoadFile($self->{mt5_redis_config})->{write};
    my $mt5_redis        = Net::Async::Redis->new(
        uri  => "redis://$mt5_redis_config->{host}:$mt5_redis_config->{port}",
        auth => $mt5_redis_config->{password});

    $self->{mt5_redis} = $mt5_redis;
    $self->add_child($mt5_redis);

    my $feed_redis_config = LoadFile($self->{feed_redis_config})->{'master-read'};
    my $feed_redis        = Net::Async::Redis->new(
        uri  => "redis://$feed_redis_config->{host}:$feed_redis_config->{port}",
        auth => $feed_redis_config->{password});

    $self->{feed_redis} = $feed_redis;
    $self->add_child($feed_redis);

    my $ua = Net::Async::HTTP->new(
        fail_on_error            => 1,
        max_connections_per_host => $self->{max_connection},
        pipeline                 => 1,
        max_in_flight            => 1,
        decode_content           => 1,
        timeout                  => 90,
        user_agent               => 'Mozilla/4.0 (perl; firebase-trading-view; tom@deriv.com)',
    );
    $self->{ua} = $ua;
    $self->add_child($ua);

    return;
}

1;
