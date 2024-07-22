package P2P;

use strict;
use warnings;

no indirect;
use Syntax::Keyword::Try;
use Date::Utility;
use List::Util                       qw(all first any min max none pairgrep uniq reduce pairfirst);
use Array::Utils                     qw(array_minus intersect);
use List::MoreUtils                  qw( minmax );
use Text::Trim                       qw(trim);
use BOM::Platform::Context           qw(localize request);
use Format::Util::Numbers            qw(financialrounding formatnumber);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Encode;
use DataDog::DogStatsd::Helper qw(stats_inc);
use POSIX                      qw(ceil);
use JSON::MaybeUTF8            qw(encode_json_utf8 encode_json_text);
use Math::BigFloat;

use Business::Config::LandingCompany::Registry;

use BOM::Platform::Event::Emitter;
use BOM::User::Utility qw(p2p_exchange_rate p2p_rate_rounding);
use BOM::Database::Model::OAuth;
use BOM::Config;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;
use BOM::Config::P2P;
use BOM::Platform::Token;
use JSON::MaybeUTF8 qw(:v1);

use Carp qw(croak);

use Log::Any qw($log);

=head1 NAME

P2P

=cut

sub new {
    my ($class, %args) = @_;

    my $client  = $args{client} // die "Client not found";
    my $context = $args{context};
    my $self    = bless {
        client  => $client,
        context => $context
    }, $class;

    return $self;
}

=head1 METHODS - P2P cashier

=cut

use constant {
    # For some currency pairs we need to have limit so big for example: VND/BTC
    # Also this limit may need to be adjusted in future.
    P2P_RATE_LOWER_LIMIT => 0.000001,    # We need it because 0.000001 < 0.1**6 is true
    P2P_RATE_UPPER_LIMIT => 10**9,

    P2P_MAXIMUM_ACTIVE_ADVERTS     => 10,
    P2P_COUNTERYPARTY_TYPE_MAPPING => {
        buy  => 'sell',
        sell => 'buy',
    },

    P2P_ORDER_DISPUTED_AT               => 'P2P::ORDER::DISPUTED_AT',
    P2P_ORDER_EXPIRES_AT                => 'P2P::ORDER::EXPIRES_AT',
    P2P_ORDER_TIMEDOUT_AT               => 'P2P::ORDER::TIMEDOUT_AT',
    P2P_ORDER_REVIEWABLE_START_AT       => 'P2P::ORDER::REVIEWABLE_START_AT',
    P2P_ORDER_PARTIES                   => 'P2P::ORDER::PARTIES',                 # as soon as order created the party will be added to this set
    P2P_ADVERTISER_BLOCK_ENDS_AT        => 'P2P::ADVERTISER::BLOCK_ENDS_AT',
    P2P_STATS_REDIS_PREFIX              => 'P2P::ADVERTISER_STATS',
    P2P_STATS_TTL_IN_DAYS               => 120,                                   # days after which to prune redis stats
    P2P_ARCHIVE_DATES_KEY               => 'P2P::AD_ARCHIVAL_DATES',
    P2P_USERS_ONLINE_KEY                => 'P2P::USERS_ONLINE',
    P2P_ONLINE_PERIOD                   => 90,
    P2P_ORDER_LAST_SEEN_STATUS          => 'P2P::ORDER::LAST_SEEN_STATUS',
    P2P_TOKEN_MIN_EXPIRY                => 2 * 60 * 60,                           # 2 hours. Sendbird token min expiry
    P2P_VERIFICATION_REQUEST_INTERVAL   => 60,                                    # min seconds between order verification requests
    P2P_VERIFICATION_TOKEN_EXPIRY       => 10 * 60,                               # tokens expire after 10 min
    P2P_VERIFICATION_MAX_ATTEMPTS       => 3,                                     # number of unsucsessful attempts before lockout
    P2P_VERIFICATION_LOCKOUT_TTL        => 30 * 60,                               # 30 min lockout after too many unsucsessful attempts
    P2P_VERIFICATION_ATTEMPT_KEY        => 'P2P::ORDER::VERIFICATION_ATTEMPT',    # sorted set to track verification attempts
    P2P_VERIFICATION_HISTORY_KEY        => 'P2P::ORDER::VERIFICATION_HISTORY',    # list of verification events for backoffice
    P2P_VERIFICATION_EVENT_KEY          => 'P2P::ORDER::VERIFICATION_EVENT',      # sorted set of verification events that occur in the future
    P2P_ADVERTISER_BAND_UPGRADE_PENDING =>
        'P2P::ADVERTISER_BAND_UPGRADE_PENDING',    #if advertiser eligible for band upgrade, store the next available band limits and stats here
    P2P_ADVERTISER_BAND_UPGRADE_COMPLETED =>
        'P2P::ADVERTISER_BAND_UPGRADE_COMPLETED',    #if upgrade success, delete entry from ADVERTISER_BAND_UPGRADE_PENDING and store data here

    # Statuses here should match the DB function p2p.is_status_final.
    P2P_ORDER_STATUS => {
        active => [qw(pending buyer-confirmed timed-out disputed)],
        final  => [qw(completed cancelled refunded dispute-refunded dispute-completed)],
    },

    # P2P_ORDER_EXPIRY_STEP here need to be always in sync with P2P_ORDER_EXPIRY_STEP in bom-backoffice/lib/BOM/DynamicSettings.pm
    P2P_ORDER_EXPIRY_STEP => 900,

    P2P_DB_ERR_MAP => {
        PP001 => "AdvertNotFound",
        PP002 => "OrderMaximumExceeded",
        PP003 => "OrderMinimumNotMet",
        PP004 => "ClientDailyOrderLimitExceeded",
        PP005 => "OrderCreateFailAmount",
        PP006 => "OrderCreateFailAmount",
        PP007 => "OrderCreateFailAmount",
        PP008 => "OrderCreateFailAmount",
        PP009 => "InvalidAdvertOwn",
        PP010 => "OrderCreateFailAmountAdvertiser",
        PP011 => "OpenOrdersDeleteAdvert",
        PP012 => "PaymentMethodRemoveActiveOrdersDB",
        PP013 => "DuplicatePaymentMethod",
        PP014 => "OrderConfirmCompleted",
        PP015 => "OrderConfirmCompleted",
        PP016 => "OrderRefundInvalid",
        PP017 => "OrderConfirmCompleted",
        PP018 => "OrderConfirmCompleted",
        PP018 => "OrderConfirmCompleted",
        PP019 => 'OrderNotFound',
        PP020 => 'AlreadyInProgress',
        PP021 => "OrderRefundInvalid",
        PP022 => 'OrderNotConfirmedPending',
        PP023 => 'OrderConfirmCompleted',
        PP024 => 'OrderReviewExists',
        PP025 => 'AdvertiserExist',
        PP026 => 'AdvertCounterpartyIneligible',
    },

};

=head2 p2p_settings

Returns general P2P settings. If subscribe:1, will add subscription_info which contains client's residence
which will be used to create subsciption channel in websocket layer and deleted as it's not part of response

Takes the following named parameters:

=over 4

=item * C<subscribe> - flag to indicate if this call includes subscription (optional)

=back

Returns, a C<hashref> containing the P2P settings.

=cut

sub p2p_settings {
    my ($self, %param) = @_;
    my $residence = $self->residence;
    die +{error_code => 'RestrictedCountry'} unless $self->_advert_config_cached->{$residence};
    my $result = BOM::User::Utility::get_p2p_settings(country => $residence);
    $result->{subscription_info} = {country => $residence} if $param{subscribe};
    return $result;
}

=head2 p2p_advertiser_create

Attempts to register client as an advertiser.
Returns the advertiser info or dies with error code.

=cut

sub p2p_advertiser_create {
    my ($self, %param) = @_;
    my $name        = trim($param{name});
    my $poa_setting = BOM::Config::Runtime->instance->app_config->payments->p2p->poa;

    die +{error_code => 'AlreadyRegistered'} if $self->_p2p_advertiser_cached;
    if ((
               ($poa_setting->enabled  && none { $self->residence eq $_ } $poa_setting->countries_excludes->@*)
            or (!$poa_setting->enabled && any { $self->residence eq $_ } $poa_setting->countries_includes->@*))
        and (not($self->client->fully_authenticated({ignore_idv => 1}) and $self->status->age_verification)))
    {
        die +{error_code => 'AuthenticationRequired'};
    }

    die +{error_code => 'AdvertiserNameRequired'} unless $name;
    die +{error_code => 'AdvertiserNameTaken'} if $self->_p2p_advertisers(unique_name => $name)->[0];

    my $lc_withdrawal_limit =
        Business::Config::LandingCompany::Registry->new()->payment_limit()
        ->{withdrawal_limits}{$self->client->landing_company->short}{lifetime_limit};
    my $p2p_create_order_chat = BOM::Config::Runtime->instance->app_config->payments->p2p->create_order_chat;

    $param{schedule} = $self->_validate_advertiser_schedule(%param);

    my ($advertiser, $token, $expiry);
    unless ($p2p_create_order_chat) {
        my ($id) = $self->db->dbic->run(
            fixup => sub {
                $_->selectrow_array("SELECT nextval('p2p.advertiser_serial')");
            });
        my $sb_api     = BOM::User::Utility::sendbird_api();
        my $sb_user_id = join '_', 'p2puser', $self->broker_code, $id, time;
        my $sb_user;
        try {
            $sb_user = $sb_api->create_user(
                user_id             => $sb_user_id,
                nickname            => $name,
                profile_url         => '',
                issue_session_token => 'true'
            );
        } catch {
            die +{error_code => 'AdvertiserCreateChatError'};
        }
        # sb api returns milliseconds timestamps
        ($token, $expiry) = ($sb_user->session_tokens->[0]{session_token}, int($sb_user->session_tokens->[0]{expires_at} / 1000));

        die +{error_code => 'AlreadyRegistered'} if $self->_p2p_advertiser_cached;

        $advertiser = $self->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM p2p.advertiser_create(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    undef,             $id,    $self->loginid, $name,                @param{qw/default_advert_description payment_info contact_info/},
                    $sb_user->user_id, $token, $expiry,        $lc_withdrawal_limit, $param{schedule},
                );
            });
    } else {
        $advertiser = $self->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM p2p.advertiser_create_v2(?, ?, ?, ?, ?, ?, ?)',
                    undef, $self->loginid, $name, @param{qw/default_advert_description payment_info contact_info/},
                    $lc_withdrawal_limit, $param{schedule},
                );
            });
    }

    unless ($self->status->age_verification or $self->status->allow_document_upload) {
        $self->status->upsert('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');
    }

    BOM::Config::Redis->redis_p2p_write->zadd(P2P_USERS_ONLINE_KEY, 'NX', time, join('::', $self->loginid, $self->residence));

    $self->_p2p_convert_advertiser_limits($advertiser);
    my $details = $self->_advertiser_details($advertiser);

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_created => {
            client_loginid => $self->loginid,
            $details->%*
        });

    return $details;
}

=head2 p2p_advertiser_info

Returns advertiser info of param{id} otherwise current client.

=cut

sub p2p_advertiser_info {
    my ($self, %param) = @_;

    my $advertiser;
    if (exists $param{id}) {
        $advertiser = $self->_p2p_advertisers(id => $param{id})->[0];
    } else {
        $advertiser = $self->_p2p_advertiser_cached;
    }

    return unless $advertiser;
    my $details = $self->_advertiser_details($advertiser);

    $details->{client_loginid} = $advertiser->{client_loginid} if $param{subscribe};    # will be removed in websocket

    return $details;
}

=head2 p2p_advertiser_list

returns advertiser partners

=cut

sub p2p_advertiser_list {
    my ($self, %param) = @_;
    my $advertiser_info = $self->_p2p_advertiser_cached;

    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser_info;

    $param{id}             = $advertiser_info->{id};
    $param{client_loginid} = $advertiser_info->{client_loginid};

    my $list = [];
    if ($param{trade_partners}) {
        $list = $self->_p2p_advertiser_trade_partners(%param);
    }

    return [map { $self->_advertiser_details($_) } $list->@*];
}

=head2 _p2p_advertiser_trade_partners

All the trade partners from DB

=cut

sub _p2p_advertiser_trade_partners {
    my ($self, %param) = @_;

    $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM p2p.advertiser_partner_list(?, ?, ?, ?, ?, ?, ?, ?)',
                {Slice => {}},
                @param{qw/id advertiser_name is_blocked is_favourite is_recommended limit offset sort_by /});
        }) // [];
}

=head2 _validate_advertiser_schedule

Validates and formats the schedule param in p2p_advertiser_create and p2p_advertiser_update.

=cut

sub _validate_advertiser_schedule {
    my ($self, %param) = @_;

    return unless exists $param{schedule};

    # An empty array will delete the schedule in db function
    my @periods = map { [$_->@{qw(start_min end_min)}] } ($param{schedule} // [])->@*;
    my @values  = map { @$_ } @periods;

    my $interval = BOM::Config::Runtime->instance->app_config->payments->p2p->business_hours_minutes_interval;

    if ($interval) {
        my $invalid_entry = first { $_ % $interval } sort grep { defined $_ } @values;
        die +{
            error_code     => 'InvalidScheduleInterval',
            message_params => [$invalid_entry, $interval]} if $invalid_entry;
    }

    die +{error_code => 'InvalidScheduleRange'} if pairfirst { defined($a) && defined($b) && $b <= $a } @values;

    return encode_json_utf8(\@periods);

}

=head2 p2p_advertiser_blocked

Returns true if the advertiser is blocked.

=cut

sub p2p_is_advertiser_blocked {
    my $self       = shift;
    my $advertiser = $self->_p2p_advertiser_cached;
    return $advertiser && !$advertiser->{is_enabled};
}

=head2 p2p_advertiser_update

Updates the client advertiser info with fields in %param.
Returns latest advertiser info.

=cut

sub p2p_advertiser_update {
    my ($self, %param) = @_;

    my $advertiser_info = $self->p2p_advertiser_info;
    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser_info;
    die +{error_code => 'AdvertiserNotApproved'}   unless $advertiser_info->{is_approved} or defined $param{is_approved};

    # Return the current information of the advertiser if nothing changed
    return $advertiser_info
        unless grep { exists $advertiser_info->{$_} and ($param{$_} // '') ne $advertiser_info->{$_} } keys %param
        or exists $param{show_name}
        or $param{upgrade_limits}
        or exists $param{schedule};

    if (exists $param{name}) {
        $param{name} = trim($param{name});
        die +{error_code => 'AdvertiserNameRequired'} unless $param{name};
        die +{error_code => 'AdvertiserNameTaken'}
            if $param{name} ne $advertiser_info->{name} and $self->_p2p_advertisers(name => $param{name})->[0];
    }

    die +{error_code => 'AdvertiserCannotListAds'} if $param{is_listed} and not $advertiser_info->{is_approved} and not $param{is_approved};
    $param{is_listed} = 0 if defined $param{is_approved} and not $param{is_approved};

    my $redis = BOM::Config::Redis->redis_p2p_write();
    my $band_upgrade;

    if ($param{upgrade_limits}) {
        $band_upgrade = $redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_info->{id})
            or die +{error_code => 'AdvertiserNotEligibleForLimitUpgrade'};

        try {
            $band_upgrade = decode_json_utf8($band_upgrade);
            $param{trade_band} = lc($band_upgrade->{target_trade_band});
        } catch ($e) {
            $log->warnf(
                'Invalid JSON stored for advertiser id: %s with data: %s at REDIS HASH KEY: %s. Error: %s',
                $advertiser_info->{id},
                $band_upgrade, P2P_ADVERTISER_BAND_UPGRADE_PENDING, $e
            );
            die +{error_code => 'P2PLimitUpgradeFailed'};
        }
    }

    $param{schedule} = $self->_validate_advertiser_schedule(%param);

    my $update = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                'SELECT * FROM p2p.advertiser_update_v2(?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, NULL, NULL, ?, NULL, ?)',
                undef,
                $advertiser_info->{id},
                @param{qw/is_approved is_listed name default_advert_description payment_info contact_info trade_band show_name schedule/});
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $advertiser_info->{id},
        });

    # double check if band upgrade was successfull
    if ($param{trade_band}) {
        $redis->hdel(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser_info->{id});

        # save data for internal email
        $band_upgrade->@{qw(old_sell_limit old_buy_limit country upgrade_date)} =
            ($advertiser_info->@{qw/daily_sell_limit daily_buy_limit/}, $self->residence, time);
        $band_upgrade->{old_block_trade} = exists $advertiser_info->{block_trade} ? 1 : 0;

        $redis->hset(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED, $advertiser_info->{id}, encode_json_utf8($band_upgrade))
            if $band_upgrade->{email_alert_required};

        BOM::Platform::Event::Emitter::emit(
            p2p_limit_changed => {
                loginid           => $self->loginid,
                advertiser_id     => $advertiser_info->{id},
                new_sell_limit    => formatnumber('amount', $band_upgrade->{account_currency}, $band_upgrade->{target_max_daily_sell}),
                new_buy_limit     => formatnumber('amount', $band_upgrade->{account_currency}, $band_upgrade->{target_max_daily_buy}),
                block_trade       => $band_upgrade->{target_block_trade},
                account_currency  => $band_upgrade->{account_currency},
                change            => 1,
                automatic_approve => 0,
            });
    }

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_updated => {
            client_loginid => $self->loginid,
        },
    );

    $self->_p2p_convert_advertiser_limits($update);
    my $response = $self->_advertiser_details($update);
    return $response;
}

=head2 p2p_advertiser_relations

Updates and returns favourite and blocked advertisers

=cut

sub p2p_advertiser_relations {
    my ($self, %param) = @_;

    my $advertiser_info = $self->_p2p_advertiser_cached;
    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser_info;

    my @relation_ids = map { ($_ // [])->@* } @param{qw(add_favourites add_blocked remove_favourites remove_blocked)};

    if (@relation_ids) {
        die +{error_code => 'AdvertiserNotApprovedForBlock'} if ($param{add_blocked} // [])->@* and not $advertiser_info->{is_approved};

        my $bar_error = $self->_p2p_get_advertiser_bar_error($advertiser_info);
        die $bar_error if $bar_error;

        die +{error_code => 'AdvertiserRelationSelf'} if any { $_ == $advertiser_info->{id} } @relation_ids;

        my %relations = $self->db->dbic->run(
            fixup => sub {
                $_->selectall_hashref('SELECT * FROM p2p.advertiser_id_check(?)', 'id', undef, \@relation_ids);
            })->%*;

        die +{error_code => 'InvalidAdvertiserID'} unless all { $relations{$_} } @relation_ids;

        $self->db->dbic->run(
            fixup => sub {
                $_->do(
                    'SELECT p2p.advertiser_relation_update(?, ?, ?, ?, ?)',
                    undef,
                    $advertiser_info->{id},
                    @param{qw/add_favourites add_blocked remove_favourites remove_blocked/});
            });

        # is_favourite/is_blocked can change on subscribed advertisers and ads
        for my $id (uniq @relation_ids) {
            BOM::Platform::Event::Emitter::emit(
                p2p_advertiser_updated => {
                    client_loginid => $relations{$id}->{loginid},
                });

            BOM::Platform::Event::Emitter::emit(
                p2p_adverts_updated => {
                    advertiser_id => $id,
                });
        }
    }

    return $self->_p2p_advertiser_relation_lists;
}

=head2 p2p_advertiser_adverts

Returns a list of adverts belonging to current client

=cut

sub p2p_advertiser_adverts {
    my ($self, %param) = @_;

    my $advertiser_info = $self->_p2p_advertiser_cached;
    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser_info;

    my $list = $self->_p2p_adverts(
        %param,
        advertiser_id => $advertiser_info->{id},
        country       => $self->residence
    );

    $list = [map { $self->filter_ad_payment_methods($_) } @$list];
    return $self->_advert_details($list);
}

=head2 p2p_advert_create

Creates an advert with %param with client as advertiser.
Returns new advert or dies with error code.

=cut

sub p2p_advert_create {
    my ($self, %param) = @_;

    my $advertiser_info = $self->_p2p_advertiser_cached;
    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser_info;
    die +{error_code => 'AdvertiserNotApproved'}   unless $advertiser_info->{is_approved};

    my $bar_error = $self->_p2p_get_advertiser_bar_error($advertiser_info);
    die $bar_error if $bar_error;

    die +{error_code => 'AdvertPaymentMethodParam'}
        if trim($param{payment_method})
        and (($param{payment_method_ids} and $param{payment_method_ids}->@*) or ($param{payment_method_names} and $param{payment_method_names}->@*));

    $param{country}          = $self->residence;
    $param{account_currency} = $self->currency;
    ($param{local_currency} //= $self->local_currency) or die +{error_code => 'NoLocalCurrency'};
    $param{advertiser_id}  = $advertiser_info->{id};
    $param{is_active}      = 1;                            # we will validate this as an active ad
    $param{local_currency} = uc($param{local_currency});

    $self->_validate_cross_border_availability if $param{local_currency} ne uc($self->local_currency);
    $self->_validate_block_trade_availability  if $param{block_trade};
    $self->_validate_advert(%param);
    %param = $self->_process_advert_params(%param);

    my $market_rate = p2p_exchange_rate($param{local_currency})->{quote};
    die +{error_code => 'AdvertFloatRateNotAllowed'} if $param{rate_type} eq 'float' and not $market_rate;

    my ($id) = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_array(
                'SELECT id FROM p2p.advert_create(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                undef,
                @param{
                    qw/advertiser_id type account_currency local_currency country amount rate min_order_amount max_order_amount description payment_method payment_info contact_info
                        payment_method_ids payment_method_names rate_type block_trade order_expiry_period min_completion_rate min_rating min_join_days eligible_countries/
                });
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $advertiser_info->{id},
        });

    # to get all the fields
    my $advert = $self->_p2p_adverts(
        id          => $id,
        market_rate => $market_rate
    )->[0];

    $advert->{payment_method_details} =
        $self->_p2p_advertiser_payment_method_details($self->_p2p_advertiser_payment_methods(advert_id => $id));

    my $response = $self->_advert_details([$advert])->[0];

    BOM::Platform::Event::Emitter::emit(
        p2p_advert_created => {
            loginid             => $self->loginid,
            created_time        => Date::Utility->new($response->{created_time})->db_timestamp,
            advert_id           => $response->{id},
            type                => $response->{type},
            account_currency    => $response->{account_currency},
            local_currency      => $response->{local_currency},
            country             => $response->{country},
            amount              => $response->{amount_display},
            rate                => $response->{rate_display},
            rate_type           => $response->{rate_type},
            min_order_amount    => $response->{min_order_amount_display},
            max_order_amount    => $response->{max_order_amount_display},
            is_visible          => $response->{is_visible},
            order_expiry_period => $response->{order_expiry_period},
        });

    # this is an inverted stat - worse rate = higher score
    my $rate_score;
    if ($param{rate_type} eq 'float') {
        my $diff = $param{type} eq 'sell' ? $param{rate} : -$param{rate};
        $rate_score = $diff / 100;    # api gets float rate as percentage
    } elsif ($market_rate) {
        my $diff = $param{type} eq 'sell' ? $param{rate} - $market_rate : $market_rate - $param{rate};
        $rate_score = $diff / $market_rate;
    }
    $self->_p2p_record_stat(
        loginid => $self->loginid,
        stat    => 'ADVERT_RATES',
        payload => [$id, $rate_score]) if defined $rate_score;

    delete $response->{days_until_archive};    # guard against almost impossible race condition
    return $response;
}

=head2 p2p_advert_info

Get a single advert by id.

=cut

sub p2p_advert_info {
    my ($self, %param) = @_;

    my ($list, $advertiser_id, $account_id);

    if ($param{id}) {
        $param{client_loginid} = $self->loginid;
        $list = $self->_p2p_adverts(%param);
        return undef unless @$list;

        if ($self->loginid eq $list->[0]{advertiser_loginid}) {
            $list->[0]{payment_method_details} =
                $self->_p2p_advertiser_payment_method_details($self->_p2p_advertiser_payment_methods(advert_id => $param{id}));
        }
        # remove invalid pms for myself/counterparties
        $list->[0] = $self->filter_ad_payment_methods($list->[0]);

    } elsif ($param{subscribe}) {
        # at this point, advertiser is subscribing to all their ads
        my $advertiser_info = $self->_p2p_advertiser_cached or die +{error_code => 'AdvertiserNotRegistered'};
        $list = $self->_p2p_adverts(
            advertiser_id => $advertiser_info->{id},
            country       => $self->residence
        );
    }

    my $details = $self->_advert_details($list);

    if ($param{subscribe}) {
        if (@$list and $list->[0]{advertiser_loginid} ne $self->loginid) {
            my $owner_client = $self->client->get_client_instance($list->[0]{advertiser_loginid}, 'replica', $self->{context});
            $account_id    = $owner_client->account->id;
            $advertiser_id = $list->[0]{advertiser_id};
        }
        $account_id    //= $self->account->id;
        $advertiser_id //= $self->_p2p_advertiser_cached->{id};    # done this way to handle non-advertisers

        BOM::User::Utility::p2p_on_advert_view($advertiser_id, {$self->loginid => {($param{id} // 'ALL') => $details}});

        $details = [] unless $param{id};                           # this call can only return a single ad

        # fields to be removed in websocket
        $details->[0]{advertiser_id}         = $advertiser_id;
        $details->[0]{advertiser_account_id} = $account_id;
    }

    return $details->[0];
}

=head2 p2p_advert_list

Get adverts for client view.
Inactive adverts, unlisted or unapproved advertisers, and max < min are excluded.

=cut

sub p2p_advert_list {
    my ($self, %param) = @_;

    if ($param{block_trade} //= 0) {
        die +{error_code => 'BlockTradeDisabled'} unless BOM::Config::Runtime->instance->app_config->payments->p2p->block_trade->enabled;
    }

    # avoid hitting db if advertiser schedule isn't available now
    return [] if $param{hide_client_schedule_unavailable} && !($self->_p2p_advertiser_cached->{is_schedule_available} // 1);

    if ($param{counterparty_type}) {
        $param{type} = P2P_COUNTERYPARTY_TYPE_MAPPING->{$param{counterparty_type}};
    }

    my @countries = $self->residence;
    if ($param{local_currency}) {
        $param{local_currency} = uc($param{local_currency});
        my $config = $BOM::Config::CurrencyConfig::ALL_CURRENCIES{uc $param{local_currency}} or die +{error_code => 'InvalidLocalCurrency'};
        push @countries, $config->{countries}->@*;
        $self->_validate_cross_border_availability if $param{local_currency} ne uc($self->local_currency);
    } elsif (not($param{advertiser_id} or $param{advertiser_name})) {
        $param{country} = $self->residence;
    }

    my %country_payment_methods = map { $_ => [keys $self->p2p_payment_methods($_)->%*] } @countries;

    my $list = $self->_p2p_adverts(
        %param,
        is_active                            => 1,
        can_order                            => 1,
        advertiser_is_approved               => 1,
        advertiser_is_listed                 => 1,
        client_loginid                       => $self->loginid,
        account_currency                     => $self->currency,
        hide_blocked                         => 1,
        country_payment_methods              => encode_json_utf8(\%country_payment_methods),
        hide_advertiser_schedule_unavailable => 1,
    );

    return $self->_advert_details($list, $param{amount});
}

=head2 p2p_advert_update

Updates the advert of $param{id} with fields in %param.
Client must be advert owner.
Cannot delete if there are open orders.
Returns latest advert info or dies with error code.

=cut

sub p2p_advert_update {
    my ($self, %param) = @_;

    my $id     = $param{id} or die +{error_code => 'AdvertNotFound'};
    my $advert = $self->_p2p_adverts(
        id      => $param{id},
        country => $self->residence
    )->[0];
    die +{error_code => 'AdvertNotFound'} unless $advert;
    die +{error_code => 'PermissionDenied'} if $advert->{advertiser_loginid} ne $self->loginid;

    $advert->{remaining_amount} = delete $advert->{remaining};    # named differently in api vs db function

    my %changed_fields = map { (exists $advert->{$_} and ($advert->{$_} // '') ne ($param{$_} // '')) ? ($_ => 1) : () } keys %param;

    # return current advert details if nothing changed
    return $self->p2p_advert_info(id => $id)
        if not $param{delete}
        and not $param{payment_method_ids}
        and not $param{payment_method_names}
        and not $param{eligible_countries}
        and not %changed_fields;

    # upgrade of legacy ads
    $param{payment_method} = ''
        if $advert->{type} eq 'sell'
        and $advert->{payment_method}
        and ($param{payment_method_ids} and $param{payment_method_ids}->@*);
    $param{payment_method} = ''
        if $advert->{type} eq 'buy'
        and $advert->{payment_method}
        and ($param{payment_method_names} and $param{payment_method_names}->@*);

    delete $advert->{payment_method_names} if $advert->{type} eq 'sell';    # the db creates this field for sell ads, but we don't want to validate it

    $param{old} = $advert;
    $self->_validate_advert(%$advert, %param) unless $param{delete};
    %param = $self->_process_advert_params(%param);

    # set special values used by p2p.advert_update_v2 to set nulls in db when undef or empty array is sent in api request
    for my $field (qw(min_completion_rate min_rating min_join_days)) {
        $param{$field} = -1 if exists $param{$field} && !defined $param{$field};
    }
    $param{eligible_countries} = ['clear']
        if exists $param{eligible_countries} && (!defined $param{eligible_countries} || $param{eligible_countries}->@* == 0);

    if ($param{is_active} and not $advert->{is_active}) {
        # reset archive date, cron will recreate it
        my $redis = BOM::Config::Redis->redis_p2p_write();
        $redis->hdel(P2P_ARCHIVE_DATES_KEY, $id);
    }

    my $updated_advert = $self->db->dbic->run(
        fixup => sub {
            my $dbh = shift;
            return $dbh->selectrow_hashref(
                'SELECT * FROM p2p.advert_update_v2(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                undef, $id,
                @param{
                    qw/is_active delete description payment_method payment_info contact_info payment_method_ids payment_method_names local_currency remaining_amount
                        rate min_order_amount max_order_amount rate_type order_expiry_period min_completion_rate min_rating min_join_days eligible_countries/
                });
        });
    $self->_p2p_db_error_handler($updated_advert);

    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $advert->{advertiser_id},
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_advert_orders_updated => {
            advert_id      => $param{id},
            client_loginid => $self->loginid
        }) if any { $changed_fields{$_} } qw/description payment_method_ids payment_method_names/;

    if ($param{delete}) {
        return {
            id      => $id,
            deleted => 1
        };
    } else {
        # to get all the fields
        return $self->p2p_advert_info(id => $id);
    }
}

=head2 p2p_order_create

Creates an order for advert $param{advert_id} with %param for client.
Advert must be active. Advertiser must be active and authenticated.
Only one active order per advert per client is allowed.
Returns new order or dies with error code.
This will move funds from advertiser to escrow.

=cut

sub p2p_order_create {
    my ($self, %param) = @_;

    my ($advert_id, $amount, $payment_info, $contact_info, $source, $rule_engine) =
        @param{qw/advert_id amount payment_info contact_info source rule_engine/};

    die 'Rule engine object is missing' unless $rule_engine;

    my $client_info = $self->_p2p_advertiser_cached;
    die +{error_code => 'AdvertiserNotFoundForOrder'}    unless $client_info;
    die +{error_code => 'AdvertiserNotApprovedForOrder'} unless $client_info->{is_approved};

    my $bar_error = $self->_p2p_get_advertiser_bar_error($client_info);
    die $bar_error if $bar_error;

    my $p2p_config               = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $limit_per_day_per_client = $p2p_config->limits->count_per_day_per_client;

    my ($day_order_count) = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM p2p.client_orders_created(?)', undef, $self->loginid);
        });

    die +{
        error_code     => 'ClientDailyOrderLimitExceeded',
        message_params => [$limit_per_day_per_client]}
        if ($day_order_count // 0) >= $limit_per_day_per_client;

    my $advert = $self->_p2p_adverts(
        id                     => $advert_id,
        is_active              => 1,
        can_order              => 1,
        advertiser_is_approved => 1,
        advertiser_is_listed   => 1,
        account_currency       => $self->currency,
        client_loginid         => $self->loginid,
    )->[0];

    die +{error_code => 'AdvertNotFound'} unless $advert and $advert_id;

    $self->_validate_cross_border_availability if lc($advert->{country}) ne lc($self->residence);
    $self->_validate_block_trade_availability  if $advert->{block_trade};

    my $legacy_ad = !($advert->{payment_method_names} and $advert->{payment_method_names}->@*);

    $advert = $self->filter_ad_payment_methods($advert);
    die +{error_code => 'AdvertNotFound'} unless $legacy_ad or $advert->{payment_method_names}->@*;

    die +{error_code => 'InvalidAdvertOwn'}      if $advert->{advertiser_loginid} eq $self->loginid;
    die +{error_code => 'AdvertiserBlocked'}     if $advert->{advertiser_blocked};
    die +{error_code => 'InvalidAdvertForOrder'} if $advert->{client_blocked};
    die +{error_code => 'AdvertCounterpartyIneligible'}
        if any { $advert->{$_} }
        qw (client_ineligible_completion_rate client_ineligible_rating client_ineligible_join_date client_ineligible_country);

    die +{error_code => 'ClientScheduleAvailability'}     unless $advert->{client_schedule_available};
    die +{error_code => 'AdvertiserScheduleAvailability'} unless $advert->{advertiser_schedule_available};

    my $advert_type = $advert->{type};

    my $advertiser_info = $self->_p2p_advertisers(id => $advert->{advertiser_id})->[0];

    $amount = financialrounding('amount', $self->currency, $amount);

    my $limit_remaining = financialrounding('amount', $self->currency,
        $advertiser_info->{'daily_' . $advert_type . '_limit'} - $advertiser_info->{'daily_' . $advert_type});
    die +{
        error_code     => 'OrderMaximumTempExceeded',
        message_params => [$limit_remaining, $self->currency]} if $amount > $limit_remaining;

    if ($advert->{rate_type} eq 'float') {
        die +{error_code => 'OrderCreateFailRateRequired'} unless defined $param{rate};

        my $allowed_slippage = $p2p_config->float_rate_order_slippage / 2;
        my $diff             = ($param{rate} - $advert->{effective_rate}) / $advert->{effective_rate};
        die +{error_code => 'OrderCreateFailRateSlippage'} if abs($diff * 100) > $allowed_slippage;
    } else {
        die +{error_code => 'OrderCreateFailRateChanged'}
            if defined $param{rate} and p2p_rate_rounding($param{rate}) != p2p_rate_rounding($advert->{rate});
    }

    my $advertiser = $self->client->get_client_instance($advertiser_info->{client_loginid}, 'replica', $self->{context});
    my ($order_type, $amount_advertiser, $amount_client);

    if ($advert_type eq 'buy') {

        $order_type        = 'sell';
        $amount_advertiser = $amount;
        $amount_client     = -$amount;
        my @payment_method_ids = ($param{payment_method_ids} // [])->@*;

        die +{error_code => 'OrderCreateFailClientBalance'} if $amount > $self->p2p_balance;
        die +{error_code => 'OrderPaymentInfoRequired'} unless trim($param{payment_info}) or @payment_method_ids;
        die +{error_code => 'OrderContactInfoRequired'} if !trim($param{contact_info});

        if (!$legacy_ad) {
            my $methods = $self->_p2p_advertiser_payment_methods(advertiser_id => $client_info->{id});
            die +{error_code => 'InvalidPaymentMethods'} unless all { exists $methods->{$_} } @payment_method_ids;
            my @order_methods = map { $methods->{$_}{method} } grep { $methods->{$_}{is_enabled} } @payment_method_ids;
            die +{error_code => 'ActivePaymentMethodRequired'} unless @order_methods;

            my $invalid_method = first {
                my $m = $_;
                none { $m eq $_ } $advert->{payment_method_names}->@*
            } @order_methods;

            if ($invalid_method) {
                my $method_defs = $self->p2p_payment_methods();
                die +{
                    error_code     => 'PaymentMethodNotInAd',
                    message_params => [$method_defs->{$invalid_method} ? $method_defs->{$invalid_method}{display_name} : $invalid_method]};
            }
        }

    } elsif ($advert_type eq 'sell') {

        $order_type        = 'buy';
        $amount_advertiser = -$amount;
        $amount_client     = $amount;

        die +{error_code => 'OrderCreateFailAmountAdvertiser'} if $amount > $advertiser->p2p_balance;
        die +{error_code => 'OrderPaymentContactInfoNotAllowed'}
            if $payment_info
            or $contact_info
            or ($param{payment_method_ids} && $param{payment_method_ids}->@*);

        ($payment_info, $contact_info) = $advert->@{qw/payment_info contact_info/};

    } else {
        die 'Invalid advert type ' . ($advert_type // 'undef') . ' for advert ' . $advert->{id};
    }

    try {
        $self->client->validate_payment(
            amount       => $amount_client,
            currency     => $advert->{account_currency},
            payment_type => 'p2p',
            rule_engine  => $rule_engine,
        );
    } catch ($e) {

        my $message = ref $e ? $e->{message_to_client} : localize('Please try later.');
        # temporary logging to allow us to see the full string
        $log->warnf('validate_payment in p2p_order_create returned a scalar! %s', $e) unless ref $e;
        die +{
            error_code     => 'OrderCreateFailClient',
            message_params => [$message],
        };
    }

    try {
        $advertiser->validate_payment(
            amount       => $amount_advertiser,
            currency     => $advert->{account_currency},
            payment_type => 'p2p',
            rule_engine  => $rule_engine,
        );
    } catch {
        die +{
            error_code => 'OrderCreateFailAmountAdvertiser',
        };
    }

    # For client inverted advert type needs to be checked, for example in a sell advert, client is buyer, so we need to check their daily_buy_limit
    my $client_limit_remaining = $client_info->{'daily_' . $order_type . '_limit'} - $client_info->{'daily_' . $order_type};
    $client_limit_remaining = financialrounding('amount', $client_info->{account_currency}, $client_limit_remaining);
    die +{
        error_code     => 'OrderMaximumTempExceeded',
        message_params => [$client_limit_remaining, $client_info->{account_currency}]}
        if $amount > $client_limit_remaining;

    my $escrow = $self->p2p_escrow($advert->{account_currency}) // die +{error_code => 'EscrowNotFound'};

    my $open_orders = $self->_p2p_orders(
        advert_id => $advert_id,
        loginid   => $self->loginid,
        status    => P2P_ORDER_STATUS->{active},
    );

    die +{error_code => 'OrderAlreadyExists'} if @{$open_orders};

    my $txn_time                          = Date::Utility->new->datetime;
    my $reversible_limit                  = BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p / 100;
    my $reversible_lookback               = BOM::Config::Runtime->instance->app_config->payments->reversible_deposits_lookback;
    my $fiat_deposit_restricted_countries = BOM::Config::Runtime->instance->app_config->payments->p2p->fiat_deposit_restricted_countries;
    my $fiat_deposit_restricted_lookback  = BOM::Config::Runtime->instance->app_config->payments->p2p->fiat_deposit_restricted_lookback;
    my $market_rate                       = p2p_exchange_rate($advert->{local_currency})->{quote};
    my $expiry                            = $advert->{order_expiry_period} //= $p2p_config->order_timeout;

    my $order = $self->db->dbic->run(
        fixup => sub {
            my $dbh = shift;

            return $dbh->selectrow_hashref(
                'SELECT * FROM p2p.order_create_v2(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)', undef,
                $advert_id,                                                                                      $self->loginid,
                $escrow->loginid,                                                                                $amount,
                $expiry,                                                                                         $payment_info,
                $contact_info,                                                                                   $source,
                $self->loginid,                                                                                  $limit_per_day_per_client,
                $txn_time,                                                                                       $reversible_limit,
                $reversible_lookback,                                                                            $param{payment_method_ids},
                $param{rate},                                                                                    $market_rate,
                $fiat_deposit_restricted_countries,                                                              $fiat_deposit_restricted_lookback
            );
        });

    $self->_p2p_db_error_handler($order);
    $self->_p2p_record_order_partners($order);

    my $redis = BOM::Config::Redis->redis_p2p_write();

    # used in p2p daemon to expire orders
    $redis->zadd(P2P_ORDER_EXPIRES_AT, Date::Utility->new($order->{expire_time})->epoch, join('|', $order->{id}, $self->loginid));

    # reset ad archive date, cron will recreate it
    $redis->hdel(P2P_ARCHIVE_DATES_KEY, $advert_id);

    BOM::Platform::Event::Emitter::emit(
        p2p_order_created => {
            client_loginid => $self->loginid,
            order_id       => $order->{id},
        });

    my $p2p_create_order_chat = BOM::Config::Runtime->instance->app_config->payments->p2p->create_order_chat;
    if ($p2p_create_order_chat) {
        BOM::Platform::Event::Emitter::emit(
            p2p_order_chat_create => {
                client_loginid => $self->loginid,
                order_id       => $order->{id},
            });
    }

    for my $order_loginid ($order->{client_loginid}, $order->{advertiser_loginid}) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $order_loginid,
            },
        );
    }

    # only update the buyer's ads, the seller's event is fired via the transaction
    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $order->{type} eq 'buy' ? $order->{client_id} : $order->{advertiser_id},
        });
    $order->{payment_method_details} = $self->_p2p_order_payment_method_details($order);
    $self->_set_last_seen_status(
        order_id => $order->{id},
        loginid  => $order->{client_loginid},
        status   => $order->{status});
    my $order_info = $self->_order_details([$order])->[0];
    $order_info->{subscription_info} = {    # will be removed in websocket (we need this for building channel name)
        advertiser_id => $client_info->{id},
        order_id      => $order->{id}} if $param{subscribe};

    return $order_info;
}

=head2 p2p_order_info

Return a single order of $param{id}

=cut

sub p2p_order_info {
    my ($self, %param) = @_;

    my $id              = $param{id}                    // return;
    my $advertiser_info = $self->_p2p_advertiser_cached // die +{error_code => 'AdvertiserNotFound'};

    # ensure client can only see their orders
    my $order = $self->_p2p_orders(
        id      => $id,
        loginid => $self->loginid
    )->[0] // return;

    $order->{payment_method_details} = $self->_p2p_order_payment_method_details($order);
    unless ($self->_is_order_status_final($order->{status})) {
        $self->_set_last_seen_status(
            order_id => $id,
            loginid  => $self->loginid,
            status   => $order->{status});
    }
    my $order_info = $self->_order_details([$order])->[0];
    $order_info->{subscription_info} = {    # will be removed in websocket (we need this for building channel name)
        advertiser_id => $advertiser_info->{id},
        order_id      => $id
    } if $param{subscribe};

    return $order_info;
}

=head2 p2p_order_list

Get orders filtered by %param.

=cut

sub p2p_order_list {
    my ($self, %param) = @_;

    $param{loginid} = $self->loginid;
    my $advertiser_info = $self->_p2p_advertiser_cached // die +{error_code => 'AdvertiserNotFound'};

    my $list        = $self->_p2p_orders(%param);
    my $orders_info = {list => $self->_order_details($list)};

    $orders_info->{subscription_info} = {    # will be removed in websocket (we need this for building channel name)
        advertiser_id => $advertiser_info->{id},
        advert_id     => $param{advert_id},
        active        => $param{active}} if $param{subscribe};

    return $orders_info;
}

=head2 p2p_order_confirm

Confirms the order of $param{id} and returns updated order.
Client = client, type = buy: order is buyer-confirmed
Client = client, type = sell: order is completed
Client = advertiser, type = buy: order is completed
Client = advertiser, type = sell: order is buyer-confirmed
Otherwise dies with error code.

=cut

sub p2p_order_confirm {
    my ($self, %param) = @_;

    my $id    = $param{id} // die +{error_code => 'OrderNotFound'};
    my $order = $self->_p2p_orders(
        id      => $id,
        loginid => $self->loginid
    )->[0] // die +{error_code => 'OrderNotFound'};
    my $role = $self->_order_ownership_type($order) or die +{error_code => 'PermissionDenied'};

    my $confirm_type = {
        sell_client     => 'sell',
        sell_advertiser => 'buy',
        buy_client      => 'buy',
        buy_advertiser  => 'sell',
    }->{$order->{type} . '_' . $role};

    my $db_confirm_func = 'p2p.order_confirm_' . $role . '_v2';
    my $new_status;

    if ($confirm_type eq 'sell') {

        die +{error_code => 'OrderNotConfirmedPending'} if $order->{status} eq 'pending';
        die +{error_code => 'OrderConfirmCompleted'}    if $order->{status} !~ /^(buyer-confirmed|timed-out|disputed)$/;
        my $escrow = $self->p2p_escrow($order->{account_currency}) // die +{error_code => 'EscrowNotFound'};

        $self->_p2p_order_confirm_verification($order, %param);

        return {
            id      => $id,
            dry_run => 1
        } if $param{dry_run};

        my $txn_time = Date::Utility->new->datetime;
        my $result   = $self->db->dbic->txn(
            fixup => sub {
                my $confirm_result = $_->selectrow_hashref("SELECT * FROM $db_confirm_func(?)", undef, $order->{id});    ## SQL safe($db_confirm_func)
                return $confirm_result if $confirm_result->{error_code};
                return $_->selectrow_hashref('SELECT * FROM p2p.order_complete_v2(?, ?, ?, ?, ?, FALSE, FALSE)',
                    undef, $order->{id}, $escrow->loginid, $param{source}, $self->loginid, $txn_time);
            });

        $self->_p2p_db_error_handler($result);
        $self->_p2p_order_completed($order);    # these functions do not consider status
        $self->_p2p_order_finalized($order);

        $new_status = $result->{status};

    } elsif ($confirm_type eq 'buy') {

        die +{error_code => 'OrderAlreadyConfirmedBuyer'}    if $order->{status} eq 'buyer-confirmed';
        die +{error_code => 'OrderAlreadyConfirmedTimedout'} if $order->{status} eq 'timed-out';
        die +{error_code => 'OrderUnderDispute'}             if $order->{status} eq 'disputed';
        die +{error_code => 'OrderConfirmCompleted'}         if $order->{status} ne 'pending';

        return {
            id      => $id,
            dry_run => 1
        } if $param{dry_run};

        my $result = $self->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref("SELECT * FROM $db_confirm_func(?)", undef, $order->{id});    ## SQL safe($db_confirm_func)
            });

        $self->_p2p_db_error_handler($result);
        $self->_p2p_order_buy_confirmed($order);                                                    # this function does not consider status
        $new_status = $result->{status};
        $self->_set_last_seen_status(
            order_id => $id,
            loginid  => $self->loginid,
            status   => $new_status
        );
    }

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $id,
            order_event    => 'confirmed',
        });

    return {
        id     => $id,
        status => $new_status
    };
}

=head2 p2p_order_cancel

Cancels the order of $param{id}.
Order must belong to the buyer.
Order must be in pending status.
This will move funds from escrow to seller.

=cut

sub p2p_order_cancel {
    my ($self, %param) = @_;
    my $id    = $param{id} // die +{error_code => 'OrderNotFound'};
    my $order = $self->_p2p_orders(id => $id)->[0];
    die +{error_code => 'OrderNotFound'} unless $order;
    die +{error_code => 'OrderNoEditExpired'}    if $order->{is_expired};
    die +{error_code => 'OrderAlreadyCancelled'} if $order->{status} eq 'cancelled';

    my $ownership_type = $self->_order_ownership_type($order);

    die +{error_code => 'PermissionDenied'}
        unless ($ownership_type eq 'client' and $order->{type} eq 'buy')
        or ($ownership_type eq 'advertiser' and $order->{type} eq 'sell');
    die +{error_code => 'PermissionDenied'} unless $order->{status} eq 'pending';

    my $escrow      = $self->p2p_escrow($order->{account_currency}) // die +{error_code => 'EscrowNotFound'};
    my $is_refunded = 0;                                                                                        # order will have cancelled status
    my $is_manual   = 0;                                                                                        # this is not a manual cancellation

    my $elapsed      = time - Date::Utility->new($order->{created_time})->epoch;
    my $grace_period = BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_grace_period * 60;    # config period is minutes
    my $buyer_fault  = $elapsed < $grace_period ? 0 : 1;    # negatively affect the buyer's completion rate when after grace period

    my $txn_time = Date::Utility->new->datetime;

    my $db_result = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.order_refund_v2(?, ?, ?, ?, ?, ?, ? ,?, ?)',
                undef, $id, $escrow->loginid, $param{source}, $self->loginid, $is_refunded, $txn_time, $is_manual, $buyer_fault, $order->{advert_id});
        });

    $self->_p2p_db_error_handler($db_result);

    $self->_p2p_order_cancelled({%$order, %$db_result});
    $self->_p2p_order_finalized($order);

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $id,
            order_event    => 'cancelled',
        });

    for my $order_loginid ($order->@{qw/client_loginid advertiser_loginid/}) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $order_loginid,
            },
        );
    }

    # only update the buyer's ads, the seller's event is fired via the transaction
    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $order->{type} eq 'buy' ? $order->{client_id} : $order->{advertiser_id},
        });

    return $db_result;
}

=head2 p2p_order_review

Creates a review for order of $param{id}.

=cut

sub p2p_order_review {
    my ($self, %param) = @_;

    my $id    = $param{order_id} // die +{error_code => 'OrderNotFound'};
    my $order = $self->_p2p_orders(
        id      => $id,
        loginid => $self->loginid,    # ensure order belongs to client
    )->[0] // die +{error_code => 'OrderNotFound'};

    die +{error_code => 'OrderReviewNotComplete'} if $order->{status} =~ /^(pending|buyer-confirmed|timed-out)$/;
    die +{error_code => 'OrderReviewStatusInvalid'} unless $order->{status} eq 'completed' and $order->{completion_time};

    my $reviewee_role = $self->loginid eq $order->{client_loginid} ? 'advertiser' : 'client';
    die +{error_code => 'OrderReviewExists'} if $order->{$reviewee_role . '_review_rating'};

    my $review_hours = BOM::Config::Runtime->instance->app_config->payments->p2p->review_period;
    die +{
        error_code     => 'OrderReviewPeriodExpired',
        message_params => [$review_hours],
        }
        if (time - Date::Utility->new($order->{completion_time})->epoch) > ($review_hours * 60 * 60);

    my ($reviewee, $reviewer) = $reviewee_role eq 'client' ? $order->@{qw(client_id advertiser_id)} : $order->@{qw(advertiser_id client_id)};

    my $review = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.order_review_v2(?, ?, ?, ?, ?)',
                undef, $id, $reviewee, $reviewer, @param{qw(rating recommended)});
        });

    $self->_p2p_db_error_handler($review);

    $review->{created_time} = Date::Utility->new($review->{created_time})->epoch;

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_updated => {
            client_loginid => $reviewee_role eq 'advertiser' ? $order->{advertiser_loginid} : $order->{client_loginid},
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $reviewee,
        });

    # only the reviewer's order will have changed
    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $id,
            order_event    => 'review_created',
            self_only      => 1,
        });

    # reviewer no longer needs notification about review period expiry
    BOM::Config::Redis->redis_p2p_write->zrem(P2P_ORDER_REVIEWABLE_START_AT, $id . '|' . $self->loginid);

    return $review;
}

=head2 p2p_chat_create

Creates a sendbird chat channel for an order, and users if required.
Both clients of the order must be P2P advertisers.

=cut

sub p2p_chat_create {    #This function and feature create_order_chat will be remove after successful realease,
                         #We are keeping just for backward compatibility
    my ($self, %param) = @_;

    return $self->p2p_create_order_chat(%param);
}

=head2 p2p_create_order_chat

This method  is called by event p2p_order_chat_create in bom-events and p2p_chat_create in this module.
Creates a sendbird chat channel for an order, and users if required.
Both clients of the order must be P2P advertisers.

=cut

sub p2p_create_order_chat {
    my ($self, %param) = @_;
    my $order_id = $param{order_id}                         // die +{error_code => 'OrderNotFound'};
    my $order    = $self->_p2p_orders(id => $order_id)->[0] // die +{error_code => 'OrderNotFound'};
    my $counterparty_loginid;

    if ($order->{advertiser_loginid} eq $self->loginid) {
        $counterparty_loginid = $order->{client_loginid};
    } elsif ($order->{client_loginid} eq $self->loginid) {
        $counterparty_loginid = $order->{advertiser_loginid};
    } else {
        die +{error_code => 'PermissionDenied'};
    }

    die +{error_code => 'OrderChatAlreadyCreated'} if $order->{chat_channel_url};
    die +{error_code => 'AdvertiserNotFoundForChat'}        unless $self->_p2p_advertiser_cached;
    die +{error_code => 'CounterpartyNotAdvertiserForChat'} unless $self->_p2p_advertisers(loginid => $counterparty_loginid)->[0];

    my $sb_api = BOM::User::Utility::sendbird_api();

    my $sb_advertiser_user_id = $order->{advertiser_chat_user_id};
    my $sb_client_user_id     = $order->{client_chat_user_id};
    foreach (0 .. 1) {
        my $sb_user_id;
        if ($_ and not $order->{advertiser_chat_user_id}) {
            $sb_advertiser_user_id = $sb_user_id = join '_', 'p2puser', $self->broker_code, $order->{advertiser_id}, time;
        } elsif (not $order->{client_chat_user_id}) {
            $sb_client_user_id = $sb_user_id = join '_', 'p2puser', $self->broker_code, $order->{client_id}, time;
        }
        if ($sb_user_id) {
            my $sb_user;
            my $nickname      = $_ ? $order->{advertiser_name} : $order->{client_name};
            my $advertiser_id = $_ ? $order->{advertiser_id}   : $order->{client_id};

            try {
                $sb_user = $sb_api->create_user(
                    user_id             => $sb_user_id,
                    nickname            => $nickname,
                    profile_url         => '',
                    issue_session_token => 'true'
                );
            } catch {
                die +{error_code => 'AdvertiserCreateChatError'};
            }

            my ($sb_user_token, $sb_user_expiry) =
                ($sb_user->session_tokens->[0]{session_token}, int($sb_user->session_tokens->[0]{expires_at} / 1000));
            $self->db->dbic->run(
                fixup => sub {
                    $_->do('SELECT * FROM p2p.advertiser_update_v2(?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)',
                        undef, $advertiser_id, $sb_user_id, $sb_user_token, $sb_user_expiry);
                });

            BOM::Platform::Event::Emitter::emit(
                p2p_advertiser_updated => {
                    client_loginid => $_ ? $order->{advertiser_loginid} : $order->{client_loginid},
                });
        }
    }

    my $sb_channel = join '_', ('p2porder', $self->broker_code, $order_id, time);
    my $sb_chat;

    try {
        $sb_chat = $sb_api->create_group_chat(
            channel_url => $sb_channel,
            user_ids    => [$sb_advertiser_user_id, $sb_client_user_id],
            name        => 'Chat about order ' . $order_id,
        );
    } catch {
        die +{error_code => 'CreateChatError'};
    }

    $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.order_update(?, ?, ?)', undef, $order_id, undef, $sb_chat->channel_url);
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $order_id,
            order_event    => 'chat_created',
        });

    return {
        channel_url => $sb_chat->channel_url,
        order_id    => $order_id,
    };
}

=head2 p2p_chat_token

Returns sendbird session token.
Creates one if it doesn't exist or has expired.

=cut

sub p2p_chat_token {
    my ($self)          = @_;
    my $advertiser_info = $self->_p2p_advertiser_cached // die +{error_code => 'AdvertiserNotFoundForChatToken'};
    my $sendbird_api    = BOM::User::Utility::sendbird_api();

    my ($token, $expiry) = $advertiser_info->@{qw(chat_token chat_token_expiry)};
    if ($token and $expiry and ($expiry - time) >= P2P_TOKEN_MIN_EXPIRY) {
        return {
            token       => $token,
            expiry_time => $expiry,
            app_id      => $sendbird_api->app_id,
        };
    } elsif ($advertiser_info->{chat_user_id}) {
        try {
            my $sb_user = WebService::SendBird::User->new(
                user_id    => $advertiser_info->{chat_user_id},
                api_client => $sendbird_api
            );
            ($token, $expiry) = $sb_user->issue_session_token()->@{qw(session_token expires_at)};
        } catch {
            die +{error_code => 'ChatTokenError'};
        }
    } else {
        try {
            $advertiser_info->{chat_user_id} = join('_', 'p2puser', $self->broker_code, $advertiser_info->{id}, time);
            my $sb_user = $sendbird_api->create_user(
                user_id             => $advertiser_info->{chat_user_id},
                nickname            => $advertiser_info->{name},
                profile_url         => '',
                issue_session_token => 'true'
            );
            ($token, $expiry) = ($sb_user->session_tokens->[0]{session_token}, int($sb_user->session_tokens->[0]{expires_at} / 1000));
        } catch ($e) {
            die +{error_code => 'ChatTokenError'};
        }
    }

    $expiry = int($expiry / 1000);    # sb api returns milliseconds timestamps

    $self->db->dbic->run(
        fixup => sub {
            $_->do(
                'SELECT * FROM p2p.advertiser_update_v2(?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)',
                undef,
                $advertiser_info->{id},
                $advertiser_info->{chat_user_id},
                $token, $expiry
            );
        });

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_updated => {
            client_loginid => $self->loginid,
        },
    );

    return {
        token       => $token,
        expiry_time => $expiry,
        app_id      => $sendbird_api->app_id,
    };
}

=head2 p2p_escrow

Gets the configured escrow account for provided currency and current landing company.

=cut

sub p2p_escrow {
    my ($self, $currency) = @_;

    my @escrow_list = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow->@*;

    foreach my $loginid (@escrow_list) {
        try {
            my $escrow = $self->client->get_client_instance($loginid, 'replica', $self->{context});

            return $escrow if $escrow && $escrow->broker eq $self->broker_code && $escrow->currency eq $currency;
        } catch {
            next;    # TODO: ideally, we should never have an error here, we should maybe log it?
        }
    }

    return undef;
}

=head2 p2p_create_order_dispute

Flags the order of $param{id} as disputed.
Client should be either buyer or seller for this order.
Only applies to the following states: C<timed-out>, C<pending>, C<buyer-confirmed>.
Although for C<pending> and C<buyer-confirmed> it should be already expired.
If successful, a redis hash is set to keep the dispute time.

It takes the following named arguments:

=over 4

=item * C<id> - the p2p order id being disputed

=item * C<dispute_reason> - the dispute reason (predefined at websocket layer, although DB field is TEXT)

=item * C<skip_livechat> - (optional) if specified and true, we won't fill the ZSET handled by P2P daemon and therefore no ticket will be raised about the dispute

=back

Returns the content of the order as parsed by C<_order_details>.

=cut

sub p2p_create_order_dispute {
    my ($self, %param) = @_;

    my $id             = $param{id} // die +{error_code => 'OrderNotFound'};
    my $dispute_reason = $param{dispute_reason};
    my $skip_livechat  = $param{skip_livechat};
    my $order          = $self->_p2p_orders(id => $id)->[0];
    die +{error_code => 'OrderNotFound'} unless $order;

    my $side = $self->_order_ownership_type($order);
    die +{error_code => 'OrderNotFound'} unless $side;

    # Some reasons may apply only to buyer/seller
    my $buyer = 1;
    $buyer = 0 if $side eq 'advertiser' and $order->{type} eq 'buy';
    $buyer = 0 if $side eq 'client'     and $order->{type} eq 'sell';
    die +{error_code => 'InvalidReasonForBuyer'}  if $buyer     and any { $dispute_reason eq $_ } qw/buyer_not_paid buyer_third_party_payment_method/;
    die +{error_code => 'InvalidReasonForSeller'} if not $buyer and $dispute_reason eq 'seller_not_released';

    # We allow buyer-confirmed due to FE relying on expire_time to show complain button.
    die +{error_code => 'OrderUnderDispute'}           if $order->{status} eq 'disputed';
    die +{error_code => 'InvalidFinalStateForDispute'} if $self->_is_order_status_final($order->{status});
    die +{error_code => 'InvalidStateForDispute'} unless grep { $order->{status} eq $_ } qw/timed-out buyer-confirmed/;
    # Confirm the order is expired
    die +{error_code => 'InvalidStateForDispute'} unless $order->{is_expired};

    my $updated_order = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.create_order_dispute(?, ?, ?)', undef, $id, $dispute_reason, $self->loginid);
        });
    unless ($skip_livechat) {
        my $p2p_redis = BOM::Config::Redis->redis_p2p_write();
        $p2p_redis->zadd(P2P_ORDER_DISPUTED_AT, Date::Utility->new()->epoch, join('|', $order->{id}, $self->broker_code));
    }

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $id,
            order_event    => 'dispute',
        });

    $self->_set_last_seen_status(
        order_id => $id,
        loginid  => $self->loginid,
        status   => $updated_order->{status});

    return $self->_order_details([$updated_order])->[0];
}

=head2 p2p_resolve_order_dispute

Resolves an order dispute, called from backoffice.

Takes the following named arguments:

=over 4

=item * C<id> - the p2p order id under dispute.

=item * C<action> - refund or complete

=item * C<staff> - backoffice staff name

=item * C<fraud> - is this being resolved as the result of fraud

=back

=cut

sub p2p_resolve_order_dispute {
    my ($self, %param) = @_;
    my ($id, $action, $staff, $fraud) = @param{qw/id action staff fraud/};

    my $order = $self->_p2p_orders(id => $id)->[0];
    die "Order not found\n"                                                 unless $order;
    die "Order is in $order->{status} status and cannot be resolved now.\n" unless $order->{status} eq 'disputed';

    my $escrow   = $self->p2p_escrow($order->{account_currency}) // die 'No escrow account defined for ' . $order->{account_currency} . "\n";
    my $txn_time = Date::Utility->new->datetime;
    my $redis    = BOM::Config::Redis->redis_p2p_write();
    my ($buyer, $seller) = $self->_p2p_order_parties($order);
    my $amount    = $order->{amount};
    my $is_manual = 1;
    my $advertiser_for_update;

    if ($action eq 'refund') {
        # resolve in favor of seller
        my $buyer_fault = 1;    # this will negatively affect the buyer's completion rate
        $self->db->dbic->run(
            fixup => sub {
                $_->do('SELECT p2p.order_refund_v2(?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    undef, $id, $escrow->loginid, 4, $staff, 't', $txn_time, $is_manual, $buyer_fault, $order->{advert_id});
            });

        if ($fraud) {
            # buyer fraud
            $self->_p2p_order_fraud('buy', $order);
        }
        $self->_p2p_record_stat(
            loginid => $buyer,
            stat    => 'BUY_COMPLETION',
            payload => [$id, 0]);
        $advertiser_for_update = $order->{type} eq 'buy' ? $order->{client_id} : $order->{advertiser_id};

    } elsif ($action eq 'complete') {
        # resolve in favor of buyer
        my $completed_order = $self->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT p2p.order_complete_v2(?, ?, ?, ?, ?, ?, ?)',
                    undef, $id, $escrow->loginid, 4, $staff, $txn_time, $is_manual, $fraud);
            });
        $self->_p2p_db_error_handler($completed_order);
        $self->_p2p_record_stat(
            loginid => $buyer,
            stat    => 'BUY_COMPLETION',
            payload => [$id, 1]);
        $self->_p2p_record_stat(
            loginid => $buyer,
            stat    => 'BUY_COMPLETED',
            payload => [$id, $amount]);
        $redis->hincrby(P2P_STATS_REDIS_PREFIX . '::TOTAL_COMPLETED', $buyer, 1);
        $redis->hincrbyfloat(P2P_STATS_REDIS_PREFIX . '::TOTAL_TURNOVER', $buyer, $amount);

        if ($fraud) {
            # seller fraud
            $self->_p2p_record_stat(
                loginid => $seller,
                stat    => 'SELL_COMPLETION',
                payload => [$id, 0]);
            $self->_p2p_order_fraud('sell', $order);
        } else {
            $self->_p2p_record_stat(
                loginid => $seller,
                stat    => 'SELL_COMPLETION',
                payload => [$id, 1]);
            $self->_p2p_record_stat(
                loginid => $seller,
                stat    => 'SELL_COMPLETED',
                payload => [$id, $amount]);
            $redis->hincrby(P2P_STATS_REDIS_PREFIX . '::TOTAL_COMPLETED', $seller, 1);
            $redis->hincrbyfloat(P2P_STATS_REDIS_PREFIX . '::TOTAL_TURNOVER', $seller, $amount);
            $self->_p2p_record_partners($order);
        }

        $advertiser_for_update = $order->{type} eq 'sell' ? $order->{client_id} : $order->{advertiser_id};

    } else {
        die "Invalid action: $action\n";
    }

    # clean up
    $redis->hdel(P2P_STATS_REDIS_PREFIX . '::BUY_CONFIRM_TIMES', $id);

    $self->_p2p_order_finalized($order);

    my $order_event = join('_', 'dispute', $fraud ? 'fraud' : (), $action);

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $self->loginid,
            order_id       => $id,
            order_event    => $order_event,
        });

    for my $order_loginid ($buyer, $seller) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $order_loginid,
            },
        );
    }

    # only update the party who did not have a transaction
    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $advertiser_for_update,
        });

    return undef;
}

=head1 Non-RPC P2P methods

The methods below are not called by RPC and, therefore, they are not needed to die in the 'P2P way'.

=head2 p2p_expire_order

Hanedles order expiry events, called by p2p_daemon via bom-events.
Deletes redis keys used by p2p_daemon if order was proceseed or already completed.
It is safe to be called multiple times.

It takes the following named arguments:

=over 4

=item * C<id> - the p2p order id that has expired

=item * C<source> - app id

=item * C<staff> - loginid or backoffice username

=back

Returns new status if it changed.

=cut

sub p2p_expire_order {
    my ($self, %param) = @_;
    my $order_id = $param{id} // die 'No id provided to p2p_expire_order';
    my $order    = $self->_p2p_orders(id => $order_id)->[0];

    die 'Invalid order provided to p2p_expire_order' unless $order;

    my $escrow   = $self->p2p_escrow($order->{account_currency}) // die 'No escrow account for ' . $order->{account_currency};
    my $txn_time = Date::Utility->new->datetime;

    my $days_for_release = BOM::Config::Runtime->instance->app_config->payments->p2p->refund_timeout;
    my $grace_period     = BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_grace_period * 60;    # config period is minutes
    my $p2p_redis        = BOM::Config::Redis->redis_p2p_write();
    my $redis_payload    = join('|', $order_id, $self->loginid);
    my $elapsed          = time - Date::Utility->new($order->{created_time})->epoch;
    my $buyer_fault      = $elapsed < $grace_period ? 0 : 1;    # negatively affect the buyer's completion rate when after grace period

    my ($old_status, $new_status, $expiry) = $self->db->dbic->txn(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM p2p.order_expire(?, ?, ?, ?, ?, ?, ?, ?)',
                undef, $order_id, $escrow->loginid, $param{source}, $param{staff}, $txn_time, $days_for_release, $order->{advert_id}, $buyer_fault);

        });

    $new_status //= '';

    my $order_complete     = ($self->_is_order_status_final($old_status) or $old_status eq 'disputed');
    my $hit_expire_refund  = ($old_status eq 'pending'         and $new_status eq 'refunded');
    my $hit_timeout        = ($old_status eq 'buyer-confirmed' and $new_status eq 'timed-out');
    my $hit_timeout_refund = ($old_status eq 'timed-out'       and $new_status eq 'refunded');

    my ($buyer, $seller) = $self->_p2p_order_parties($order);

    # order hit timed out
    if ($hit_timeout) {
        $p2p_redis->zadd(P2P_ORDER_TIMEDOUT_AT, Date::Utility->new($expiry)->epoch, $redis_payload);
    }

    # order hit expiry time, or was already done, or already timed-out
    if ($hit_expire_refund or $hit_timeout or $order_complete or $old_status eq 'timed-out') {
        $p2p_redis->zrem(P2P_ORDER_EXPIRES_AT, $redis_payload);
    }

    # order hit time out expiry, or was already done (includes refunded)
    if ($hit_timeout_refund or $order_complete) {
        $p2p_redis->zrem(P2P_ORDER_TIMEDOUT_AT, $redis_payload);
    }

    if ($hit_expire_refund or $hit_timeout) {
        stats_inc('p2p.order.expired');

        BOM::Platform::Event::Emitter::emit(
            p2p_order_updated => {
                client_loginid => $self->loginid,
                order_id       => $order_id,
                order_event    => 'expired',
            });
    }

    if ($hit_expire_refund) {
        # this counts as a manual cancel
        $self->_p2p_order_cancelled($order);
    }

    if ($hit_timeout_refund) {
        # degrade the buyer's completion rate but don't count as cancel
        $self->_p2p_record_stat(
            loginid => $buyer,
            stat    => 'BUY_COMPLETION',
            payload => [$order_id, 0]);

        stats_inc('p2p.order.timeout_refund');

        BOM::Platform::Event::Emitter::emit(
            p2p_order_updated => {
                client_loginid => $self->loginid,
                order_id       => $order_id,
                order_event    => 'timeout_refund',
            });
    }

    if ($hit_expire_refund or $hit_timeout_refund) {
        # order was refunded, need to update both advertisers
        for my $order_loginid ($buyer, $seller) {
            BOM::Platform::Event::Emitter::emit(
                p2p_advertiser_updated => {
                    client_loginid => $order_loginid,
                },
            );
        }

        # only update the buyer's ads, the seller's event is triggered by the transaction
        BOM::Platform::Event::Emitter::emit(
            p2p_adverts_updated => {
                advertiser_id => $order->{type} eq 'buy' ? $order->{client_id} : $order->{advertiser_id},
            });

        $self->_p2p_order_finalized($order);
    }

    return $new_status;
}

=head1 Private P2P methods

=head2 _get_last_seen_status
Sample hash key: 4|CR90000053 (order_id|login_id)
Returns last seen status for specified client based on hash key in redis
Last seen status here means the latest order status seen by client while the order is active 

=cut

sub _get_last_seen_status {
    my ($self, %param) = @_;
    my $redis     = BOM::Config::Redis->redis_p2p();
    my $order_key = $param{order_id} . "|" . $param{loginid};
    return $redis->hget(P2P_ORDER_LAST_SEEN_STATUS, $order_key);
}

=head2 _set_last_seen_status

Sample hash key: 4|CR90000053 (order_id|login_id)
Sets last seen status for specified client based on hash key (order_id|login_id) in redis
This subroutine invoked only if there is an update to an active order of client and that update is seen by client 

=cut

sub _set_last_seen_status {
    my ($self, %param) = @_;
    my $p2p_redis = BOM::Config::Redis->redis_p2p_write();
    my $order_key = $param{order_id} . "|" . $param{loginid};
    $p2p_redis->hset(P2P_ORDER_LAST_SEEN_STATUS, $order_key, $param{status});
}

=head2 _validate_cross_border_availability

Check if client's residence is restricted from cross border ad feature
If yes, advertiser not allowed to create ads, view ads or create order against ads that is not from his local currency

=cut

sub _validate_cross_border_availability {
    my $self                                      = shift;
    my $p2p_config                                = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $restricted_countries_for_cross_border_ads = $p2p_config->cross_border_ads_restricted_countries // [];
    die +{error_code => 'CrossBorderNotAllowed'}
        if any { lc($_) eq $self->residence } $restricted_countries_for_cross_border_ads->@*;
    return 1;
}

=head2 _validate_block_trade_availability

Check if client is allowed to do block trade and block trading is globally enabled.

=cut

sub _validate_block_trade_availability {
    my $self = shift;

    die +{error_code => 'BlockTradeNotAllowed'}
        if any { !defined $self->_p2p_advertiser_cached->{$_} } qw(block_trade_min_order_amount block_trade_max_order_amount);
    die +{error_code => 'BlockTradeDisabled'} unless BOM::Config::Runtime->instance->app_config->payments->p2p->block_trade->enabled;
}

=head2 _process_advert_params

Common processing of ad params for p2p_advert_create and p2p_advert_update.

=cut

sub _process_advert_params {
    my ($self, %param) = @_;

    $param{min_completion_rate} = $param{min_completion_rate} / 100     if $param{min_completion_rate};
    $param{eligible_countries}  = [sort $param{eligible_countries}->@*] if $param{eligible_countries};

    return %param;
}

=head2 _p2p_advertisers

Returns a list of advertisers filtered by id and/or loginid.

=cut

sub _p2p_advertisers {
    my ($self, %param) = @_;

    # don't call $self->_p2p_advertiser_cached or we will have deep recursion
    my $self_id = $self->{_p2p_advertiser_cached} ? $self->{_p2p_advertiser_cached}{id} : undef;

    my $advertisers = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM p2p.advertiser_list_v2(?, ?, ?, ?, ?)',
                {Slice => {}},
                @param{qw/id loginid name unique_name/}, $self_id
            );
        });

    $self->_p2p_convert_advertiser_limits($_) for @$advertisers;
    return $advertisers;
}

=head2 _p2p_advertiser_cached

Cache of p2p_advertiser record for the current client.
We often need to get it more than once for a single RPC call.
In tests you will need to delete this every time you update an advertiser and call another RPC method.

=cut

sub _p2p_advertiser_cached {
    my $self = shift;

    return $self->{_p2p_advertiser_cached} //= $self->_p2p_advertisers(loginid => $self->loginid)->[0];
}

=head2 _p2p_convert_advertiser_limits

Converts limits to advertier's account currency. Values are changed in-place.

=cut

sub _p2p_convert_advertiser_limits {
    my ($self, $advertiser) = @_;

    for my $amt (qw/daily_buy_limit daily_sell_limit min_order_amount max_order_amount min_balance/) {
        next unless defined $advertiser->{$amt};
        $advertiser->{$amt} = convert_currency($advertiser->{$amt}, $advertiser->{limit_currency}, $advertiser->{account_currency});
    }

    return $advertiser;
}

=head2 _p2p_adverts

Gets adverts from DB. Most params are passed directly to db function p2p.advert_list().

To note:

=over 4

=item * C<payment_method> is an arrayref of payment method names.

=back

=cut

sub _p2p_adverts {
    my ($self, %param) = @_;

    my ($limit, $offset) = @param{qw/limit offset/};
    die +{error_code => 'InvalidListLimit'}  if defined $limit  && $limit <= 0;
    die +{error_code => 'InvalidListOffset'} if defined $offset && $offset < 0;

    my $payments_config = BOM::Config::Runtime->instance->app_config->payments;
    $param{max_order}                         = convert_currency($payments_config->p2p->limits->maximum_order, 'USD', $self->currency);
    $param{reversible_limit}                  = $payments_config->reversible_balance_limits->p2p / 100;
    $param{reversible_lookback}               = $payments_config->reversible_deposits_lookback;
    $param{fiat_deposit_restricted_countries} = $payments_config->p2p->fiat_deposit_restricted_countries;
    $param{fiat_deposit_restricted_lookback}  = $payments_config->p2p->fiat_deposit_restricted_lookback;
    $param{default_order_expiry}              = $payments_config->p2p->order_timeout;
    $param{advertiser_name} =~ s/([%_])/\\$1/g         if $param{advertiser_name};
    $param{local_currency} = uc $param{local_currency} if $param{local_currency};

    unless ($param{market_rate}) {
        my @currencies;
        if ($param{local_currency}) {
            @currencies = ($param{local_currency});
        } else {
            my @countries = $param{country} ? ($param{country}) : keys BOM::Config::P2P::available_countries()->%*;
            for my $country (@countries) {
                push @currencies,
                    BOM::Config::CurrencyConfig::local_currency_for_country(
                    country        => $country,
                    include_legacy => 1
                    );
            }
        }
        my %market_rate_map = map { $_ => p2p_exchange_rate($_)->{quote} } @currencies;
        $param{market_rate_map} = encode_json_utf8(\%market_rate_map);
    }

    for my $field (qw/id advert_id limit offset/) {
        $param{$field} += 0 if defined $param{$field};
    }

    my @fields = qw(id account_currency advertiser_id is_active type country can_order max_order advertiser_is_listed advertiser_is_approved
        client_loginid limit offset show_deleted sort_by advertiser_name reversible_limit reversible_lookback payment_method
        use_client_limits favourites_only hide_blocked market_rate rate_type local_currency market_rate_map country_payment_methods
        fiat_deposit_restricted_countries fiat_deposit_restricted_lookback block_trade hide_ineligible default_order_expiry
        hide_advertiser_schedule_unavailable hide_client_schedule_unavailable);

    $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM p2p.advert_list(' . (join ',', map { '?' } 0 .. $#fields) . ')', {Slice => {}}, @param{@fields});
        }) // [];
}

=head2 _p2p_orders

Gets orders from DB.
$param{loginid} will match on advert advertiser loginid or order client loginid.
$param{status} if provided must by an arrayref.

=cut

sub _p2p_orders {
    my ($self, %param) = @_;

    $param{status} = $param{active} ? P2P_ORDER_STATUS->{active} : P2P_ORDER_STATUS->{final}
        if exists $param{active};

    croak 'Invalid status format'
        if defined $param{status}
        && ref $param{status} ne 'ARRAY';

    my ($limit, $offset) = @param{qw/limit offset/};
    die +{error_code => 'InvalidListLimit'}  if defined $limit  && $limit <= 0;
    die +{error_code => 'InvalidListOffset'} if defined $offset && $offset < 0;

    for my $field (qw/id advert_id limit offset/) {
        $param{$field} += 0 if defined $param{$field};
    }

    my ($date_from, $date_to) = @param{qw/date_from date_to/};
    if ($date_from and $date_from = eval { Date::Utility->new($param{date_from}) } // die +{error_code => 'InvalidDateFormat'}) {
        $param{start_time} = $date_from->datetime_yyyymmdd_hhmmss;
    }

    if ($date_to and $date_to = eval { Date::Utility->new($param{date_to}) } // die +{error_code => 'InvalidDateFormat'}) {
        $param{end_time} = $date_to->datetime_yyyymmdd_hhmmss;
        ## If we were passed in a date (but not an epoch or full timestamp)
        ## add in one day, so that 2018-04-07 grabs the entire day by doing
        ## a "date_to < 2018-04-08 00:00:000'
        $date_to->plus_time_interval('1d') unless $date_to->second + 0;
        $param{end_time} = $date_to->db_timestamp;
    }

    return $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM p2p.order_list(?, ?, ?, ?, ?, ?, ?, ?)',
                {Slice => {}},
                @param{qw/id advert_id loginid status start_time end_time limit offset/});
        }) // [];
}

=head2 _validate_advert

Validation for advert create and update.
Simply calls all the advert validation methods.

=cut

sub _validate_advert {
    my ($self, %param) = @_;

    $self->_validate_advert_amount(%param);
    $self->_validate_advert_rates(%param);
    $self->_validate_advert_min_max(%param);
    $self->_validate_advert_order_expiry_period(%param);
    $self->_validate_advert_duplicates(%param);
    $self->_validate_advert_payment_method_type(%param);
    $self->_validate_advert_payment_method_ids(%param);
    $self->_validate_advert_payment_method_names(%param);
    $self->_validate_advert_payment_contact_info(%param);
    $self->_validate_advert_counterparty_terms(%param);
}

=head2 _validate_advert_amount

Validation of advert amount field.

=cut

sub _validate_advert_amount {
    my ($self, %param) = @_;

    my $limit_key = $param{block_trade} ? 'block_trade' : 'limits';
    my $global_max_ad =
        convert_currency(BOM::Config::Runtime->instance->app_config->payments->p2p->$limit_key->maximum_advert, 'USD', $param{account_currency});

    if ($param{remaining_amount}) {
        # calculate amount for validation purposes, but it will be reculated in the db to avoid race conditions
        my $orders = $self->_p2p_orders(
            advert_id => $param{id},
            status    => [qw/pending buyer-confirmed timed-out disputed completed dispute-completed/],
        );

        my $used_amount = reduce { $a + $b->{amount} } 0, @$orders;
        my $new_amount  = $param{remaining_amount} + $used_amount;

        if ($new_amount > $global_max_ad) {
            die +{
                error_code     => 'MaximumExceededNewAmount',
                message_params => [
                    financialrounding('amount', $param{account_currency}, $global_max_ad),
                    financialrounding('amount', $param{account_currency}, $used_amount),
                    financialrounding('amount', $param{account_currency}, $new_amount),
                    $param{account_currency}
                ],
            };
        }
    }

    if (not $param{id} and $param{amount} > $global_max_ad) {
        die +{
            error_code     => 'MaximumExceeded',
            message_params => [financialrounding('amount', $param{account_currency}, $global_max_ad), $param{account_currency}],
        };
    }
}

=head2 _validate_advert_rates

Validation of advert rate and rate_type fields.

=cut

sub _validate_advert_rates {
    my ($self, %param) = @_;

    my $country_advert_config = $self->_advert_config_cached->{$param{country}} or die +{error_code => 'RestrictedCountry'};
    my $type_changed          = $param{rate_type} ne ($param{old}->{rate_type} // '');
    my $active_changed        = ($param{is_active} and $param{is_active} != ($param{old}->{is_active} // 0));

    if ($param{rate_type} eq 'float') {
        die +{error_code => 'AdvertFloatRateNotAllowed'}
            if ($type_changed and $country_advert_config->{float_ads} ne 'enabled')
            or ($active_changed and $country_advert_config->{float_ads} eq 'disabled');

        # too much precision
        if (my ($decimals) = $param{rate} =~ /\.(\d+)$/) {
            die +{error_code => 'FloatRatePrecision'} if length($decimals) > 2;
        }

        die +{error_code => 'FloatRatePrecision'} if $param{rate} =~ /e-/;

        # within currency specific range
        my $range = BOM::Config::P2P::currency_float_range($param{local_currency}) / 2;
        if (abs($param{rate}) > $range) {
            die +{
                error_code     => 'FloatRateTooBig',
                message_params => [sprintf('%.02f', $range)],
            };
        }
    } else {    # fixed rate
        die +{error_code => 'AdvertFixedRateNotAllowed'}
            if ($type_changed and $country_advert_config->{fixed_ads} ne 'enabled')
            or ($active_changed and $country_advert_config->{fixed_ads} eq 'disabled');

        # rate min
        if ($param{rate} < P2P_RATE_LOWER_LIMIT) {
            die +{
                error_code     => 'RateTooSmall',
                message_params => [sprintf('%.06f', P2P_RATE_LOWER_LIMIT)],
            };
        }

        # rate max
        if ($param{rate} > P2P_RATE_UPPER_LIMIT) {
            die +{
                error_code     => 'RateTooBig',
                message_params => [sprintf('%.02f', P2P_RATE_UPPER_LIMIT)],
            };
        }
    }
}

=head2 _validate_advert_min_max

Validation of advert min and max order fields.

=cut

sub _validate_advert_min_max {
    my ($self, %param) = @_;

    my ($band_min_order, $band_max_order, $global_max_order);

    if ($param{block_trade}) {
        ($band_min_order, $band_max_order) = $self->_p2p_advertiser_cached->@{qw(block_trade_min_order_amount block_trade_max_order_amount)};
    } else {
        ($band_min_order, $band_max_order) = $self->_p2p_advertiser_cached->@{qw(min_order_amount max_order_amount)};
        $global_max_order =
            convert_currency(BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_order, 'USD', $param{account_currency});
    }

    # min_order_amount limit
    if (defined $band_min_order and $param{min_order_amount} < $band_min_order) {
        die +{
            error_code     => 'BelowPerOrderLimit',
            message_params => [financialrounding('amount', $param{account_currency}, $band_min_order), $param{account_currency}],
        };
    }

    # actual min order would round to zero
    if ($param{rate_type} eq 'fixed') {
        my $min_price = $param{rate} * $param{min_order_amount};

        if (financialrounding('amount', $param{local_currency}, $min_price) == 0) {
            die +{
                error_code     => 'MinPriceTooSmall',
                message_params => [0]};
        }
    }

    # max_order_amount limit
    my $max_order = min grep { defined $_ } ($global_max_order, $band_max_order);
    if ($max_order and $param{max_order_amount} > $max_order) {
        die +{
            error_code     => 'MaxPerOrderExceeded',
            message_params => [financialrounding('amount', $param{account_currency}, $max_order), $param{account_currency}],
        };
    }

    die +{error_code => 'InvalidMinMaxAmount'} if $param{min_order_amount} > $param{max_order_amount};
}

=head2 _validate_advert_order_expiry_period

Check if order expiry period provided satisfies these conditions:
(1) Must be a multiple of P2P_ORDER_EXPIRY_STEP
(2) Must be in between max and min of order expiry options (includes default order timeout period)

Point (2) will also ensure value > 0

=cut

sub _validate_advert_order_expiry_period {
    my ($self, %param) = @_;

    my $order_expiry_period = $param{order_expiry_period} // return;

    return if (($param{old}->{order_expiry_period} // -1) == $param{order_expiry_period});

    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my ($min, $max) = minmax($p2p_config->order_expiry_options->@*, $p2p_config->order_timeout);
    if (   ($order_expiry_period % P2P_ORDER_EXPIRY_STEP)
        || $order_expiry_period < $min
        || $order_expiry_period > $max)
    {
        die +{error_code => 'InvalidOrderExpiryPeriod'};
    }
    return 1;
}

=head2 _validate_advert_payment_contact_info

Validation of advert payment_info and contact_info fields.

=cut

sub _validate_advert_payment_contact_info {
    my ($self, %param) = @_;

    return unless $param{type} eq 'sell';
    die +{error_code => 'AdvertContactInfoRequired'} if not trim($param{contact_info});
    die +{error_code => 'AdvertPaymentInfoRequired'}
        if not trim($param{payment_info})
        and not($param{payment_method_ids} and $param{payment_method_ids}->@*);
}

=head2 _validate_advert_duplicates

Checks for duplicates and limits on numbers of similar ads.

=cut

sub _validate_advert_duplicates {
    my ($self, %param) = @_;

    return unless $param{is_active};

    my @active_ads = $self->_p2p_adverts(
        advertiser_id => $param{advertiser_id},
        is_active     => 1,
        country       => $self->residence,
        block_trade   => $param{block_trade} // 0,
    )->@*;

    # exclude ads that ran out of money - this should be removed when FE can enable/disable ads
    @active_ads = grep { $_->{remaining} >= $_->{min_order_amount} } @active_ads;

    # exclude ad being edited
    @active_ads = grep { not $param{id} or $_->{id} != $param{id} } @active_ads;

    # maximum active ads (all)
    die +{error_code => 'AdvertMaxExceeded'} if @active_ads >= P2P_MAXIMUM_ACTIVE_ADVERTS;

    my @active_ads_same_type =
        grep { $_->{type} eq $param{type} and $_->{local_currency} eq $param{local_currency} and $_->{account_currency} eq $param{account_currency} }
        @active_ads;

    # maximum acive ads of same type
    my $same_type_limit = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_ads_per_type;
    if (@active_ads_same_type >= $same_type_limit) {
        die +{
            error_code     => 'AdvertMaxExceededSameType',
            message_params => [$same_type_limit],
        };
    }

    # duplicate rate, type and currency pair
    if (defined $param{rate}) {
        die +{error_code => 'DuplicateAdvert'}
            if any { p2p_rate_rounding($_->{rate}) == p2p_rate_rounding($param{rate}) and $_->{rate_type} eq $param{rate_type} }
            @active_ads_same_type;
    }

    # cannot have an ad with overlapping min/max amounts and same type + currencies
    die +{error_code => 'AdvertSameLimits'} if any {
               ($param{min_order_amount} >= $_->{min_order_amount} and $param{min_order_amount} <= $_->{max_order_amount})
            or ($param{max_order_amount} >= $_->{min_order_amount} and $param{max_order_amount} <= $_->{max_order_amount})
            or ($param{max_order_amount} >= $_->{max_order_amount} and $param{min_order_amount} <= $_->{min_order_amount})
    } @active_ads_same_type;
}

=head2 _validate_advert_payment_method_type

Checks if active ads have valid payment methods.

=cut

sub _validate_advert_payment_method_type {
    my ($self, %param) = @_;

    return unless $param{is_active};

    if ($param{type} eq 'sell') {
        die +{error_code => 'AdvertPaymentMethodRequired'}
            unless trim($param{payment_method})
            or ($param{payment_method_ids} and $param{payment_method_ids}->@*);
    } elsif ($param{type} eq 'buy') {
        die +{error_code => 'AdvertPaymentMethodRequired'}
            unless trim($param{payment_method})
            or ($param{payment_method_names} and $param{payment_method_names}->@*);
    }
}

=head2 _validate_advert_payment_method_ids

Validation of advert payment_method_ids field.

=cut

sub _validate_advert_payment_method_ids {
    my ($self, %param) = @_;

    return unless $param{payment_method_ids};

    if ($param{type} eq 'buy') {
        die +{error_code => 'AdvertPaymentMethodsNotAllowed'} if $param{payment_method_ids}->@*;
        return;
    }

    my $methods = $self->_p2p_advertiser_payment_methods(advertiser_id => $param{advertiser_id});
    my @method_names =
        map { $methods->{$_}{method} } grep { exists $methods->{$_} and $methods->{$_}{is_enabled} } $param{payment_method_ids}->@*;

    die +{error_code => 'InvalidPaymentMethods'}       if any { !$methods->{$_} } $param{payment_method_ids}->@*;
    die +{error_code => 'ActivePaymentMethodRequired'} if $param{is_active} and not @method_names and not trim($param{payment_method});

    # No pm name that was available when an active order was created may be removed from the ad
    if ($param{active_orders}) {
        my $orders = $self->_p2p_orders(
            advert_id => $param{id},
            status    => P2P_ORDER_STATUS->{active});

        my @used_methods = map { ($_->{advert_payment_method_names} // [])->@* } @$orders;
        if (my ($removed_method) = array_minus(@used_methods, @method_names)) {
            my $method_defs = $self->p2p_payment_methods();

            my @payment_methods_display_name_array;
            foreach (@used_methods) {
                push(@payment_methods_display_name_array, $method_defs->{$_}{display_name});
            }

            my $payment_methods_display_name_joined = join(', ', sort @payment_methods_display_name_array);

            die +{
                error_code     => 'PaymentMethodRemoveActiveOrders',
                message_params => [$payment_methods_display_name_joined]};
        }
    }
}

=head2 _validate_advert_payment_method_names

Validation of advert _validate_advert_payment_method_names field.

=cut

sub _validate_advert_payment_method_names {
    my ($self, %param) = @_;

    return unless $param{payment_method_names} and $param{payment_method_names}->@*;

    die +{error_code => 'PaymentMethodsDisabled'}
        unless BOM::Config::Runtime->instance->app_config->payments->p2p->payment_methods_enabled;

    die +{error_code => 'AdvertPaymentMethodNamesNotAllowed'} if $param{type} eq 'sell';

    my $method_defs = $self->p2p_payment_methods($self->residence);

    if (my $invalid_method = first { not exists $method_defs->{$_} } $param{payment_method_names}->@*) {
        die +{
            error_code     => 'InvalidPaymentMethod',
            message_params => [$invalid_method]};
    }
}

=head2 _validate_advert_counterparty_terms

Validate fields for advert terms.

=cut

sub _validate_advert_counterparty_terms {
    my ($self, %param) = @_;

    if ($param{eligible_countries} && $param{eligible_countries}->@*) {
        my %p2p_countries = BOM::Config::P2P::available_countries()->%*;
        if (my $invalid_country = first { !$p2p_countries{$_} } $param{eligible_countries}->@*) {
            die +{
                error_code     => 'InvalidCountry',
                message_params => [$invalid_country]};
        }
    }
}

=head2 _p2p_advertiser_payment_methods

Gets advertiser payment methods from DB.
Returns hashref keyed by id.

=cut

sub _p2p_advertiser_payment_methods {
    my ($self, %param) = @_;
    my $result = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_hashref(
                'SELECT id, is_enabled, method, params, used_by_adverts, used_by_orders FROM p2p.advertiser_payment_method_list(?, ?, ?, ?)',
                'id',
                {Slice => {}},
                @param{qw/advertiser_id advert_id order_id is_enabled/});
        }) // {};

    for my $item (values %$result) {
        delete $item->{id};
        $item->{fields} = decode_json_utf8(delete $item->{params});
    }
    return $result;
}

=head2 _p2p_advertiser_payment_method_details

Format advertiser payment methods for websocket response.

=cut

sub _p2p_advertiser_payment_method_details {
    my ($self, $methods) = @_;
    my $defs = $self->p2p_payment_methods();

    for my $id (keys %$methods) {
        my $method_def = $defs->{$methods->{$id}{method}};
        $methods->{$id}{$_} = $method_def->{$_}   for qw/display_name type/;
        $methods->{$id}{$_} = $methods->{$id}{$_} for qw/used_by_adverts used_by_orders/;
        for my $field (keys $method_def->{fields}->%*) {
            $methods->{$id}{fields}{$field} = {
                $method_def->{fields}{$field}->%*,
                value => $methods->{$id}{fields}{$field} // '',
            };
        }
    }
    return $methods;
}

=head2 _p2p_order_payment_method_details

Gets the active payment methods for a given order.
Completed orders are ignored.

=cut

sub _p2p_order_payment_method_details {
    my ($self, $order) = @_;

    return if $self->_is_order_status_final($order->{status});

    my $methods =
        $order->{type} eq 'buy'
        ? $self->_p2p_advertiser_payment_methods(
        advert_id  => $order->{advert_id},
        is_enabled => 1
        )
        : $self->_p2p_advertiser_payment_methods(
        order_id   => $order->{id},
        is_enabled => 1
        );

    return unless %$methods;

    my @client_pms     = keys $self->p2p_payment_methods($order->{client_country})->%*;
    my @advertiser_pms = keys $self->p2p_payment_methods($order->{advertiser_country})->%*;
    my @valid_pms      = intersect(@client_pms, @advertiser_pms);
    my @invalid_ids    = grep {
        my $method = $methods->{$_}{method};
        none { $_ eq $method } @valid_pms
    } keys %$methods;
    delete $methods->@{@invalid_ids};

    return $self->_p2p_advertiser_payment_method_details($methods);
}

=head2 _order_ownership_type

Returns whether client is the buyer or seller of the order.

=cut

sub _order_ownership_type {
    my ($self, $order_info) = @_;

    return 'client' if $order_info->{client_loginid} eq $self->loginid;

    return 'advertiser' if $order_info->{advertiser_loginid} eq $self->loginid;

    return '';
}

=head2 _p2p_order_confirm_verification

Handles email verification if required by the country.

=cut

sub _p2p_order_confirm_verification {
    my ($self, $order, %param) = @_;

    my $p2p_config    = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my @countries     = $p2p_config->transaction_verification_countries->@*;
    my $all_countries = $p2p_config->transaction_verification_countries_all;

    return if (not $all_countries) and none { $self->residence eq $_ } @countries;
    return if $all_countries       and any { $self->residence eq $_ } @countries;

    my $order_id      = $order->{id};
    my $redis         = BOM::Config::Redis->redis_p2p_write;
    my $attempts_key  = P2P_VERIFICATION_ATTEMPT_KEY . "::$order_id";
    my $history_key   = P2P_VERIFICATION_HISTORY_KEY . "::$order_id";
    my $event_postfix = '|' . $order_id . '|' . $self->loginid;         # note here we use seller loginid, but other places use order client_loginid

    # after 3 failures, lockout for 30 min
    if ($redis->zrangebyscore($attempts_key, '-Inf', time)->@* >= P2P_VERIFICATION_MAX_ATTEMPTS) {
        $redis->zadd(P2P_VERIFICATION_EVENT_KEY, time + P2P_VERIFICATION_LOCKOUT_TTL, "LOCKOUT$event_postfix");
        $redis->zrem(P2P_VERIFICATION_EVENT_KEY, "REQUEST_BLOCK$event_postfix", "TOKEN_VALID$event_postfix");

        $redis->del($attempts_key);
        $redis->rpush($history_key, time . '|30 minute lockout for too many failures');

        # revert order expiry and timeout
        my $cli_redis_item  = $order_id . '|' . $order->{client_loginid};         # these items have order client_loginid not seller loginid
        my $original_expiry = Date::Utility->new($order->{expire_time})->epoch;

        if (my $order_expiry = $redis->zscore(P2P_ORDER_EXPIRES_AT, $cli_redis_item)) {
            $redis->zadd(P2P_ORDER_EXPIRES_AT, $original_expiry, $cli_redis_item) if $order_expiry > $original_expiry;
        }

        if (my $order_timedout_at = $redis->zscore(P2P_ORDER_TIMEDOUT_AT, $cli_redis_item)) {
            $redis->zadd(P2P_ORDER_TIMEDOUT_AT, $original_expiry, $cli_redis_item) if $order_timedout_at > $original_expiry;
        }

        BOM::Platform::Event::Emitter::emit(
            p2p_order_updated => {
                client_loginid => $self->loginid,
                order_id       => $order_id,
            });
    }

    my $lockout_expiry = $redis->zscore(P2P_VERIFICATION_EVENT_KEY, "LOCKOUT$event_postfix") // 0;
    if ($lockout_expiry > time) {
        die +{
            error_code     => 'ExcessiveVerificationFailures',
            message_params => [ceil(($lockout_expiry - time) / 60)],
        };
    }

    if (my $code = $param{verification_code}) {
        my $token = BOM::Platform::Token->new({token => $code});

        unless ($token->token and $token->{created_for} eq 'p2p_order_confirm' and $token->email eq $self->email) {
            $redis->zrem($attempts_key, $code);           # don't count expired code twice
            $redis->zadd($attempts_key, time, rand());    # record a failed attempt at current time
            $redis->rpush($history_key, time . '|Invalid/expired token provided');
            die +{error_code => 'InvalidVerificationToken'};
        }

        if ($param{dry_run}) {
            $redis->rpush($history_key, time . '|Successful dry run');
        } else {
            $token->delete_token;
        }

    } else {
        # max 1 request per minute
        my $request_expiry = $redis->zscore(P2P_VERIFICATION_EVENT_KEY, "REQUEST_BLOCK$event_postfix") // 0;
        if ($request_expiry > time) {
            $redis->rpushx($history_key, time . '|Too frequent requests for verification email');
            die +{
                error_code     => 'ExcessiveVerificationRequests',
                message_params => [$request_expiry - time],
            };
        }

        $redis->zadd(P2P_VERIFICATION_EVENT_KEY, time + P2P_VERIFICATION_REQUEST_INTERVAL, "REQUEST_BLOCK$event_postfix");

        my $code = BOM::Platform::Token->new({
                email       => $self->email,
                created_for => 'p2p_order_confirm',
                expires_in  => P2P_VERIFICATION_TOKEN_EXPIRY,
            })->token;

        my $token_expiry = time + P2P_VERIFICATION_TOKEN_EXPIRY;
        $redis->zadd($attempts_key, $token_expiry, $code);    # record a failed attempt for future, on token expiry

        $redis->zadd(P2P_VERIFICATION_EVENT_KEY, $token_expiry, "TOKEN_VALID$event_postfix");

        # extend order expiry and timeout to match token expiry
        my $cli_redis_item = $order_id . '|' . $order->{client_loginid};    # these items have order client_loginid not seller loginid

        if (my $order_expiry = $redis->zscore(P2P_ORDER_EXPIRES_AT, $cli_redis_item)) {    #todo: simplify when redis version supports GT flag
            $redis->zadd(P2P_ORDER_EXPIRES_AT, $token_expiry, $cli_redis_item) if $token_expiry > $order_expiry;
        }

        if (my $order_timedout_at = $redis->zscore(P2P_ORDER_TIMEDOUT_AT, $cli_redis_item)) {
            my $adjusted_expiry = $token_expiry - ($p2p_config->refund_timeout * 24 * 60 * 60);    # setting is days
            $redis->zadd(P2P_ORDER_TIMEDOUT_AT, $adjusted_expiry, $cli_redis_item) if $adjusted_expiry > $order_timedout_at;
        }

        if (my $url = BOM::Database::Model::OAuth->new->get_verification_uri_by_app_id($param{source})) {

            $url .= "/p2p" if $url !~ /\/p2p$/;    #this line can be removed once "/p2p" is added to DP2P verification_uri in oauth.apps DB table
            $url .= "?action=p2p_order_confirm&order_id=$order_id&code=$code&lang=" . request->language;

            BOM::Platform::Event::Emitter::emit(
                p2p_order_confirm_verify => {
                    loginid          => $self->loginid,
                    verification_url => $url,
                    code             => $code,
                    order_id         => $order_id,
                    order_amount     => $order->{amount},
                    order_currency   => $order->{account_currency},
                    buyer_name       => $order->{advert_type} eq 'buy' ? $order->{advertiser_name} : $order->{client_name},
                    live_chat_url    => request->brand->live_chat_url({
                            app_id   => request->app_id,
                            language => request->language
                        }
                    ),
                    password_reset_url => request->brand->password_reset_url({
                            source   => request->app_id,
                            language => request->language
                        }
                    ),
                });

            BOM::Platform::Event::Emitter::emit(
                p2p_order_updated => {
                    client_loginid => $self->loginid,
                    order_id       => $order_id,
                });
        }

        $redis->rpush($history_key, time . '|Requested email');

        die +{error_code => 'OrderEmailVerificationRequired'};
    }

    return;
}

=head2 _advertiser_details

Prepares advertiser fields for client display.
Takes and returns single advertiser.

=cut

sub _advertiser_details {
    my ($self, $advertiser) = @_;

    my $stats_days = 30;                              # days for stats, per websocket fields description
    my $loginid    = $advertiser->{client_loginid};
    my %stats      = $self->_p2p_advertiser_stats($advertiser->{client_loginid}, $stats_days * 24)->%*;

    my $details = {
        id                         => $advertiser->{id},
        name                       => $advertiser->{name},
        created_time               => Date::Utility->new($advertiser->{created_time})->epoch,
        is_approved                => $advertiser->{is_approved},
        is_listed                  => $advertiser->{is_listed},
        default_advert_description => $advertiser->{default_advert_description} // '',
        buy_completion_rate        => $stats{buy_completion_rate},
        buy_orders_count           => $stats{buy_completed_count},
        buy_orders_amount          => $stats{buy_completed_amount},
        sell_completion_rate       => $stats{sell_completion_rate},
        sell_orders_count          => $stats{sell_completed_count},
        sell_orders_amount         => $stats{sell_completed_amount},
        total_completion_rate      => defined $advertiser->{completion_rate} ? sprintf("%.1f", $advertiser->{completion_rate} * 100) : undef,
        total_orders_count         => $stats{total_orders_count},
        total_turnover             => $stats{total_turnover},
        buy_time_avg               => $stats{buy_time_avg},
        release_time_avg           => $stats{release_time_avg},
        cancel_time_avg            => $stats{cancel_time_avg},
        partner_count              => $stats{partner_count},
        advert_rates               => $stats{advert_rates},
        rating_average             => defined $advertiser->{rating_average} ? sprintf('%.2f', $advertiser->{rating_average}) : undef,
        rating_count               => $advertiser->{rating_count} // 0,
        recommended_average        => defined $advertiser->{recommended_average} ? sprintf('%.1f', $advertiser->{recommended_average} * 100) : undef,
        recommended_count          => defined $advertiser->{recommended_average} ? $advertiser->{recommended_count}                          : undef,
        $self->_p2p_advertiser_online_status($advertiser->{client_loginid}, $advertiser->{country} // $self->residence),
    };

    if ($advertiser->{show_name}) {
        $details->{first_name} = $advertiser->{first_name};
        $details->{last_name}  = $advertiser->{last_name};
    }

    if ($advertiser->{schedule}) {
        $details->{is_schedule_available} = $advertiser->{is_schedule_available};
        try {
            my $schedule = decode_json_utf8($advertiser->{schedule});
            $details->{schedule} = [map { {start_min => $_->[0], end_min => $_->[1]} } @$schedule];
        } catch ($e) {
            $log->warnf('invalid advertiser schedule json for %s: %s', $advertiser->{client_loginid}, $e);
        }
    } else {
        $details->{is_schedule_available} = 1;
    }

    # only advertiser themself can see these fields
    if ($self->loginid eq $loginid) {
        $details->{payment_info}      = $advertiser->{payment_info} // '';
        $details->{contact_info}      = $advertiser->{contact_info} // '';
        $details->{chat_user_id}      = $advertiser->{chat_user_id};
        $details->{chat_token}        = $advertiser->{chat_token} // '';
        $details->{show_name}         = $advertiser->{show_name};
        $details->{balance_available} = $self->p2p_balance;
        $details->{withdrawal_limit} =
            defined $advertiser->{withdrawal_limit}
            ? financialrounding('amount', $advertiser->{account_currency}, $advertiser->{withdrawal_limit})
            : undef;
        $details->{basic_verification} = $self->status->age_verification    ? 1 : 0;
        $details->{full_verification}  = $self->client->fully_authenticated ? 1 : 0;
        $details->{cancels_remaining}  = $self->_p2p_advertiser_cancellations->{remaining};
        $details->{blocked_by_count}   = $advertiser->{blocked_by_count}
            // 0;    # only p2p.advertiser_create does not return it, but there it must be zero

        for my $amt (qw/daily_buy daily_sell/) {
            # advertiser_create does not return these fields, but they must be zero
            $details->{$amt} = financialrounding('amount', $advertiser->{account_currency}, $advertiser->{$amt} // 0);
        }

        for my $limit (qw/daily_buy_limit daily_sell_limit min_order_amount max_order_amount min_balance/) {
            $details->{$limit} = financialrounding('amount', $advertiser->{account_currency}, $advertiser->{$limit})
                if defined $advertiser->{$limit};
        }

        $details->{block_trade} = {
            min_order_amount => financialrounding('amount', $advertiser->{account_currency}, $advertiser->{block_trade_min_order_amount}),
            max_order_amount => financialrounding('amount', $advertiser->{account_currency}, $advertiser->{block_trade_max_order_amount}),
            }
            if $self->_can_advertiser_block_trade($advertiser);

        if ($advertiser->{blocked_until}) {
            my $block_time = Date::Utility->new($advertiser->{blocked_until});
            $details->{blocked_until} = $block_time->epoch if Date::Utility->new->is_before($block_time);
        }

        # if ad rates are not in the default setting, FE needs to know if advertiser has active ads of each type
        my $country_advert_config = $self->_advert_config_cached->{$self->residence};
        if ($country_advert_config && ($country_advert_config->{fixed_ads} ne 'enabled' || $country_advert_config->{float_ads} ne 'disabled')) {
            my $ads = $self->_p2p_adverts(
                advertiser_id => $advertiser->{id},
                is_active     => 1,
                country       => $self->residence,
            );
            for my $type ('fixed', 'float') {
                my $count = scalar grep { $_->{rate_type} eq $type } @$ads;
                $details->{'active_' . $type . '_ads'} = $count if $count > 0;
            }
        }

        if ($advertiser->{is_approved} and not($details->{blocked_until})) {
            my $redis = BOM::Config::Redis->redis_p2p();
            if (my $upgrade = $redis->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $advertiser->{id})) {
                try {
                    $upgrade = decode_json_utf8($upgrade);

                    $details->{upgradable_daily_limits} = {
                        max_daily_sell => financialrounding('amount', $advertiser->{account_currency}, $upgrade->{target_max_daily_sell}),
                        max_daily_buy  => financialrounding('amount', $advertiser->{account_currency}, $upgrade->{target_max_daily_buy}),
                        block_trade    => $upgrade->{target_block_trade},
                    };

                } catch ($e) {
                    $log->warnf("Invalid JSON stored for advertiser id %s with data '%s' in redis hash key %s: %s",
                        $advertiser->{id}, $upgrade, P2P_ADVERTISER_BAND_UPGRADE_PENDING, $e);
                }
            }
        }

    } else {
        $details->{basic_verification} = $advertiser->{basic_verification};
        $details->{full_verification}  = $advertiser->{full_verification};
        $details->{is_blocked}         = $advertiser->{blocked};
        $details->{is_favourite}       = $advertiser->{favourite};
        $details->{is_recommended}     = $advertiser->{recommended};
    }

    return $details;
}

=head2 _advert_details

Prepares advert fields for client display.
Takes and returns an arrayref of advert.

=cut

sub _advert_details {
    my ($self, $list, $amount) = @_;
    my (@results, $payment_method_defs);

    my $redis      = BOM::Config::Redis->redis_p2p();
    my $start_ts   = Date::Utility->new->minus_time_interval('720h')->epoch;      # for 30 day completed order count
    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

    for my $advert (@$list) {
        my $is_advert_owner = $self->loginid eq $advert->{advertiser_loginid};
        my $result          = +{
            account_currency  => $advert->{account_currency},
            country           => $advert->{country},
            created_time      => Date::Utility->new($advert->{created_time})->epoch,
            description       => $advert->{description} // '',
            id                => $advert->{id},
            is_active         => $advert->{is_active},
            local_currency    => $advert->{local_currency},
            payment_method    => $advert->{payment_method},
            type              => $advert->{type},
            counterparty_type => P2P_COUNTERYPARTY_TYPE_MAPPING->{$advert->{type}},
            price             => $advert->{effective_rate} ? p2p_rate_rounding($advert->{effective_rate}) * ($amount // 1) : undef,
            price_display     => $advert->{effective_rate}
            ? financialrounding('amount', $advert->{local_currency}, p2p_rate_rounding($advert->{effective_rate}) * ($amount // 1))
            : undef,
            rate         => $advert->{rate},
            rate_type    => $advert->{rate_type},
            rate_display => $advert->{rate_type} eq 'float' ? sprintf('%+.2f', $advert->{rate})
            : p2p_rate_rounding($advert->{rate}, display => 1),
            effective_rate                 => p2p_rate_rounding($advert->{effective_rate}),
            effective_rate_display         => p2p_rate_rounding($advert->{effective_rate}, display => 1),
            order_expiry_period            => $advert->{order_expiry_period} // $p2p_config->order_timeout,
            min_order_amount_limit         => $advert->{min_order_amount},
            min_order_amount_limit_display => financialrounding('amount', $advert->{account_currency}, $advert->{min_order_amount}),
            max_order_amount_limit         => $advert->{max_order_amount_actual},
            max_order_amount_limit_display => financialrounding('amount', $advert->{account_currency}, $advert->{max_order_amount_actual}),
            block_trade                    => $advert->{block_trade},
            defined $advert->{min_completion_rate} ? (min_completion_rate => sprintf('%.1f', $advert->{min_completion_rate} * 100)) : (),
            defined $advert->{min_rating}          ? (min_rating          => sprintf('%.2f', $advert->{min_rating}))                : (),
            defined $advert->{min_join_days}       ? (min_join_days       => $advert->{min_join_days})                              : (),
            defined $advert->{eligible_countries}  ? (eligible_countries  => $advert->{eligible_countries})                         : (),

            # to match p2p_advert_list params, plus checking if advertiser blocked
            is_visible => (
                all { $advert->{$_} } qw(is_active can_order advertiser_is_approved advertiser_is_listed advertiser_schedule_available)
                    and ($is_advert_owner ? 1 : not($advert->{advertiser_blocked} or $advert->{client_blocked}))
                    # when client is ad owner, no point checking advertiser_blocked/client_blocked since it's always FALSE
                    and (($advert->{payment_method_names} // [])->@* or $advert->{payment_method}) and not $advert->{is_deleted}
                ) ? 1
            : 0,
            advertiser_details => {
                id                    => $advert->{advertiser_id},
                name                  => $advert->{advertiser_name},
                total_completion_rate => defined $advert->{advertiser_completion} ? sprintf("%.1f", $advert->{advertiser_completion} * 100)
                : undef,
                $advert->{advertiser_show_name}
                ? (
                    first_name => $advert->{advertiser_first_name},
                    last_name  => $advert->{advertiser_last_name},
                    )
                : (),
                ($self->loginid ne $advert->{advertiser_loginid})
                ? (
                    is_favourite   => $advert->{advertiser_favourite},
                    is_blocked     => $advert->{advertiser_blocked},
                    is_recommended => $advert->{advertiser_recommended},
                    )
                : (),
                completed_orders_count =>
                    $redis->zcount(join('::', P2P_STATS_REDIS_PREFIX, $advert->{advertiser_loginid}, 'BUY_COMPLETED'),  $start_ts, '+inf') +
                    $redis->zcount(join('::', P2P_STATS_REDIS_PREFIX, $advert->{advertiser_loginid}, 'SELL_COMPLETED'), $start_ts, '+inf'),
                rating_average      => defined $advert->{advertiser_rating_average} ? sprintf('%.2f', $advert->{advertiser_rating_average}) : undef,
                rating_count        => $advert->{advertiser_rating_count} // 0,
                recommended_average => defined $advert->{advertiser_recommended_average}
                ? sprintf('%.1f', $advert->{advertiser_recommended_average} * 100)
                : undef,
                # calculate the number of positive recommendations
                recommended_count => defined $advert->{advertiser_recommended_average} ? $advert->{advertiser_recommended_count} : undef,
                $self->_p2p_advertiser_online_status($advert->{advertiser_loginid}, $advert->{advertiser_country}),
                is_schedule_available => $advert->{advertiser_schedule_available},
            },
        };

        if ($advert->{is_active} and $is_advert_owner) {
            if (my $archive_date = $redis->hget(P2P_ARCHIVE_DATES_KEY, $advert->{id})) {
                my $days = Date::Utility->new($archive_date)->days_between(Date::Utility->new);
                $result->{days_until_archive} = $days < 0 ? 0 : $days;
            }
        }

        my $payment_method_names = $advert->{available_payment_method_names};
        $payment_method_names = $advert->{payment_method_names} unless @$payment_method_names;

        if ($payment_method_names and @$payment_method_names) {
            $payment_method_defs //= $self->p2p_payment_methods();
            $result->{payment_method_names} = [
                sort map { $payment_method_defs->{$_}{display_name} }
                grep     { exists $payment_method_defs->{$_} } @$payment_method_names
            ];
        }

        if ($is_advert_owner) {
            # only the advert owner can see these fields
            $result->{payment_info}             = $advert->{payment_info} // '';
            $result->{contact_info}             = $advert->{contact_info} // '';
            $result->{amount}                   = financialrounding('amount', $advert->{account_currency}, $advert->{amount});
            $result->{amount_display}           = formatnumber('amount', $advert->{account_currency}, $advert->{amount});
            $result->{min_order_amount}         = financialrounding('amount', $advert->{account_currency}, $advert->{min_order_amount});
            $result->{min_order_amount_display} = formatnumber('amount', $advert->{account_currency}, $advert->{min_order_amount});
            $result->{max_order_amount}         = financialrounding('amount', $advert->{account_currency}, $advert->{max_order_amount});
            $result->{max_order_amount_display} = formatnumber('amount', $advert->{account_currency}, $advert->{max_order_amount});
            $result->{remaining_amount}         = financialrounding('amount', $advert->{account_currency}, $advert->{remaining});
            $result->{remaining_amount_display} = formatnumber('amount', $advert->{account_currency}, $advert->{remaining});
            $result->{active_orders}            = $advert->{active_orders};
            $result->{payment_method_details}   = $advert->{payment_method_details}
                if $advert->{payment_method_details} and $advert->{payment_method_details}->%*;

            if (not $result->{is_visible}) {
                my @reasons;
                my $country_advert_config = $self->_advert_config_cached->{$advert->{country}} // {};
                if ($country_advert_config->{$advert->{rate_type} . '_ads'} eq 'disabled') {
                    @reasons = ('advert_' . $advert->{rate_type} . '_rate_disabled');    # this reason replaces all others
                } else {
                    push @reasons, 'advert_inactive'  if not $advert->{is_active};
                    push @reasons, 'advert_max_limit' if $advert->{max_order_exceeded};
                    # advert_min_limit should only be returned for the exact reason of band minimum
                    push @reasons, 'advert_min_limit'
                        if ($advert->{advertiser_band_min_balance} // 0) > $advert->{min_order_amount}
                        and $advert->{max_order_amount_actual} < $advert->{advertiser_band_min_balance}
                        and $advert->{max_order_amount_actual} > $advert->{min_order_amount};
                    push @reasons, 'advert_remaining'          if $advert->{remaining} < $advert->{min_order_amount};
                    push @reasons, 'advert_no_payment_methods' if not(($advert->{payment_method_names} // [])->@* or $advert->{payment_method});
                    push @reasons, 'advertiser_ads_paused'     if not $advert->{advertiser_is_listed};
                    push @reasons, 'advertiser_approval'       if not $advert->{advertiser_is_approved};
                    push @reasons, 'advertiser_balance'
                        if $advert->{type} eq 'sell' and $advert->{advertiser_available_balance} < $advert->{min_order_amount};
                    push @reasons, 'advertiser_daily_limit'
                        if defined($advert->{advertiser_available_limit})
                        and $advert->{advertiser_available_limit} < $advert->{min_order_amount};
                    push @reasons, 'advertiser_temp_ban'               if $advert->{advertiser_temp_ban};
                    push @reasons, 'advertiser_block_trade_ineligible' if $advert->{block_trade} and not $advert->{advertiser_can_block_trade};
                    push @reasons, 'advertiser_schedule'               if !$advert->{advertiser_schedule_available};
                }
                $result->{visibility_status} = \@reasons;
            }
        } else {
            push $result->{eligibility_status}->@*, 'completion_rate' if $advert->{client_ineligible_completion_rate};
            push $result->{eligibility_status}->@*, 'country'         if $advert->{client_ineligible_country};
            push $result->{eligibility_status}->@*, 'join_date'       if $advert->{client_ineligible_join_date};
            push $result->{eligibility_status}->@*, 'rating_average'  if $advert->{client_ineligible_rating};
            $result->{is_eligible}                  = $result->{eligibility_status} ? 0 : 1;
            $result->{is_client_schedule_available} = $advert->{client_schedule_available};
        }

        push @results, $result;
    }

    return \@results;
}

=head2 _order_details

Prepares order fields for client display.
Takes and returns an arrayref of orders.

=cut

sub _order_details {
    my ($self, $list) = @_;
    my (@results, $payment_method_defs, $review_hours);

    my $redis = BOM::Config::Redis->redis_p2p();

    for my $order (@$list) {
        my $role = $self->_order_ownership_type($order);

        my $result = +{
            account_currency   => $order->{account_currency},
            created_time       => Date::Utility->new($order->{created_time})->epoch,
            payment_info       => $order->{payment_info} // '',
            contact_info       => $order->{contact_info} // '',
            expiry_time        => Date::Utility->new($order->{expire_time})->epoch,
            id                 => $order->{id},
            is_incoming        => $role eq 'advertiser' ? 1 : 0,
            local_currency     => $order->{local_currency},
            amount             => $order->{amount},
            amount_display     => financialrounding('amount', $order->{account_currency}, $order->{amount}),
            price              => p2p_rate_rounding($order->{rate}) * $order->{amount},
            price_display      => financialrounding('amount', $order->{local_currency}, p2p_rate_rounding($order->{rate}) * $order->{amount}),
            rate               => p2p_rate_rounding($order->{rate}),
            rate_display       => p2p_rate_rounding($order->{rate}, display => 1),
            status             => $order->{status},
            type               => $order->{type},
            chat_channel_url   => $order->{chat_channel_url} // '',
            advertiser_details => {
                id         => $order->{advertiser_id},
                name       => $order->{advertiser_name},
                loginid    => $order->{advertiser_loginid},
                first_name => $order->{advertiser_first_name},
                last_name  => $order->{advertiser_last_name},
                ($role eq 'client' and exists $order->{advertiser_recommended}) ? (is_recommended => $order->{advertiser_recommended}) : (),
                $self->_p2p_advertiser_online_status($order->{advertiser_loginid}, $order->{advertiser_country}),

            },
            client_details => {
                id         => $order->{client_id}   // '',
                name       => $order->{client_name} // '',
                loginid    => $order->{client_loginid},
                first_name => $order->{client_first_name},
                last_name  => $order->{client_last_name},
                ($role eq 'advertiser' and exists $order->{client_recommended}) ? (is_recommended => $order->{client_recommended}) : (),
                $self->_p2p_advertiser_online_status($order->{client_loginid}, $order->{client_country}),
            },
            advert_details => {
                id             => $order->{advert_id},
                description    => $order->{advert_description} // '',
                type           => $order->{advert_type},
                payment_method => 'bank_transfer',                      # must be bank_transfer to not break mobile!
                block_trade    => $order->{advert_block_trade},
            },
            dispute_details => {
                dispute_reason   => $order->{dispute_reason},
                disputer_loginid => $order->{disputer_loginid},
            },
            ($order->{payment_method}) ? (payment_method => $order->{payment_method}) : (),
            ($role eq 'client' and $order->{advertiser_review_rating})
            ? (
                review_details => {
                    created_time => Date::Utility->new($order->{advertiser_review_time})->epoch,
                    rating       => $order->{advertiser_review_rating},
                    recommended  => $order->{advertiser_review_recommended},
                })
            : (),
            ($role eq 'advertiser' and $order->{client_review_rating})
            ? (
                review_details => {
                    created_time => Date::Utility->new($order->{client_review_time})->epoch,
                    rating       => $order->{client_review_rating},
                    recommended  => $order->{client_review_recommended},
                })
            : (),
        };

        unless ($self->_is_order_status_final($order->{status})) {
            my $last_seen_status = $self->_get_last_seen_status(
                order_id => $order->{id},
                loginid  => $self->loginid
            );
            $result->{is_seen} = $order->{status} eq ($last_seen_status // '') ? 1 : 0;
        }

        if ($order->{payment_method_details} and $order->{payment_method_details}->%*) {
            $result->{payment_method_details} = $order->{payment_method_details};
            my (undef, $seller) = $self->_p2p_order_parties($order);
            if ($seller ne $self->loginid) {
                # only the seller (pm owner) can see these fields
                delete $result->{payment_method_details}{$_}->@{qw(used_by_adverts used_by_orders)} for keys $result->{payment_method_details}->%*;
            }
        } elsif ($order->{payment_method}) {
            $payment_method_defs //= $self->p2p_payment_methods();
            $result->{payment_method_names} =
                [map { $payment_method_defs->{$_}{display_name} } grep { exists $payment_method_defs->{$_} } split ',', $order->{payment_method}];
        }

        $result->{is_reviewable} = 0;

        if ($order->{completion_time}) {
            $result->{completion_time} = Date::Utility->new($order->{completion_time})->epoch;
            if ($order->{status} eq 'completed' and not $result->{review_details}) {
                $review_hours //= BOM::Config::Runtime->instance->app_config->payments->p2p->review_period;
                $result->{is_reviewable} = 1 if (time - $result->{completion_time}) <= ($review_hours * 60 * 60);
            }
        }

        if ($redis->exists(P2P_VERIFICATION_HISTORY_KEY . '::' . $order->{id})) {
            my (undef, $seller) = $self->_p2p_order_parties($order);
            my $event_postfix = '|' . $order->{id} . '|' . $seller;

            my $token_expiry = $redis->zscore(P2P_VERIFICATION_EVENT_KEY, "TOKEN_VALID$event_postfix");

            $result->{verification_pending} = ($token_expiry // 0) > time ? 1 : 0;
            $result->{expiry_time}          = $token_expiry if ($token_expiry // 0) > $result->{expiry_time};

            if ($seller eq $self->loginid) {
                $result->{verification_token_expiry} = $token_expiry if $result->{verification_pending};

                my $request_expiry = $redis->zscore(P2P_VERIFICATION_EVENT_KEY, "REQUEST_BLOCK$event_postfix") // 0;
                my $lockout_expiry = $redis->zscore(P2P_VERIFICATION_EVENT_KEY, "LOCKOUT$event_postfix")       // 0;

                $result->{verification_next_request}  = $request_expiry if $request_expiry > time;
                $result->{verification_lockout_until} = $lockout_expiry if $lockout_expiry > time;
            }
        }

        push @results, $result;
    }

    return \@results;
}

=head2 _is_order_status_final

Returns true if the status is final.

=cut

sub _is_order_status_final {
    my (undef, $status) = @_;
    return any { $status eq $_ } P2P_ORDER_STATUS->{final}->@*;
}

=head2 _can_advertiser_block_trade

Returns true if if advertiser (raw db response) has block trading ability.

=cut

sub _can_advertiser_block_trade {
    my (undef, $advertiser) = @_;
    return (all { defined $advertiser->{$_} } qw(block_trade_min_order_amount block_trade_max_order_amount)) ? 1 : 0;
}

=head2 _p2p_record_stat

Records time-sensitive stats for a P2P advertiser.

Takes the following arguments:

=over

=item * C<loginid> - advertiser loginid

=item * C<stat> - name of stat

=item * C<payload> - (array) items to be joined to make unique payload

=back

=cut

sub _p2p_record_stat {
    my ($self, %param) = @_;
    my $redis    = BOM::Config::Redis->redis_p2p_write();
    my $prune_ts = Date::Utility->new->minus_time_interval(P2P_STATS_TTL_IN_DAYS . 'd')->epoch;
    my $expiry   = P2P_STATS_TTL_IN_DAYS * 24 * 60 * 60;
    my $key      = join '::', P2P_STATS_REDIS_PREFIX, $param{loginid}, $param{stat};
    my $item     = join '|',  $param{payload}->@*;
    $redis->zadd($key, ($param{ts} // time), $item);
    $redis->expire($key, $expiry);
    $redis->zremrangebyscore($key, '-inf', '(' . $prune_ts);

    return undef;
}

=head2 _p2p_record_partners

Records trading partners for a successfully completed order.

Takes the following arguments:

=over

=item * C<order> - order hashref

=back

=cut

sub _p2p_record_partners {
    my ($self, $order) = @_;

    my $redis = BOM::Config::Redis->redis_p2p_write();
    $redis->sadd(join('::', P2P_STATS_REDIS_PREFIX, $order->{client_loginid},     'ORDER_PARTNERS'), $order->{advertiser_id});
    $redis->sadd(join('::', P2P_STATS_REDIS_PREFIX, $order->{advertiser_loginid}, 'ORDER_PARTNERS'), $order->{client_id});
    return;
}

=head2 _p2p_record_order_partners

Records order partners for a created order.

Takes the following arguments:

=over

=item * C<order> - order hashref

=back

=cut

sub _p2p_record_order_partners {
    my ($self, $order) = @_;

    my $redis = BOM::Config::Redis->redis_p2p_write();
    $redis->sadd(join('::', P2P_ORDER_PARTIES, $order->{client_id}),     $order->{advertiser_id});
    $redis->sadd(join('::', P2P_ORDER_PARTIES, $order->{advertiser_id}), $order->{client_id});
    return;
}

=head2 _p2p_advertiser_stats

Returns P2P advertiser statistics

Example usage:

    $self->_p2p_order_stats_get('CR001', 24);

Takes the following arguments:

=over 4

=item * C<$loginid> - loginid of advertiser

=item * C<hours> - period to generate stats in hours, lifetime if 0 or undef

=back

Returns hashref.

=cut

sub _p2p_advertiser_stats {
    my ($self, $loginid, $hours) = @_;
    my $start_ts   = $hours ? Date::Utility->new->minus_time_interval($hours . 'h')->epoch : '-inf';
    my $key_prefix = P2P_STATS_REDIS_PREFIX . '::' . $loginid . '::';
    my $redis      = BOM::Config::Redis->redis_p2p();

    # items are "id|amount", "id|time" or "id|boolean"
    my %raw;
    for my $key (
        qw/BUY_COMPLETED SELL_COMPLETED ORDER_CANCELLED BUY_FRAUD SELL_FRAUD CANCEL_TIMES BUY_TIMES RELEASE_TIMES BUY_COMPLETION SELL_COMPLETION ADVERT_RATES/
        )
    {
        $raw{$key} = [map { (split /\|/, $_)[1] } $redis->zrangebyscore($key_prefix . $key, $start_ts, '+inf')->@*];
    }

    my $stats = {
        total_orders_count  => $redis->hget(P2P_STATS_REDIS_PREFIX . '::TOTAL_COMPLETED', $loginid) // 0,
        total_turnover      => financialrounding('amount', $self->currency, $redis->hget(P2P_STATS_REDIS_PREFIX . '::TOTAL_TURNOVER', $loginid) // 0),
        buy_completed_count => scalar $raw{BUY_COMPLETED}->@*,
        buy_completed_amount  => financialrounding('amount', $self->currency, List::Util::sum($raw{BUY_COMPLETED}->@*) // 0),
        sell_completed_count  => scalar $raw{SELL_COMPLETED}->@*,
        sell_completed_amount => financialrounding('amount', $self->currency, List::Util::sum($raw{SELL_COMPLETED}->@*) // 0),
        cancel_count          => scalar $raw{ORDER_CANCELLED}->@*,
        cancel_amount         => financialrounding('amount', $self->currency, List::Util::sum($raw{ORDER_CANCELLED}->@*) // 0),
        buy_fraud_count       => scalar $raw{BUY_FRAUD}->@*,
        buy_fraud_amount      => financialrounding('amount', $self->currency, List::Util::sum($raw{BUY_FRAUD}->@*) // 0),
        sell_fraud_count      => scalar $raw{SELL_FRAUD}->@*,
        sell_fraud_amount     => financialrounding('amount', $self->currency, List::Util::sum($raw{SELL_FRAUD}->@*) // 0),
        buy_time_avg        => $raw{BUY_TIMES}->@*     ? sprintf("%.0f", List::Util::sum($raw{BUY_TIMES}->@*) / $raw{BUY_TIMES}->@*)         : undef,
        release_time_avg    => $raw{RELEASE_TIMES}->@* ? sprintf("%.0f", List::Util::sum($raw{RELEASE_TIMES}->@*) / $raw{RELEASE_TIMES}->@*) : undef,
        cancel_time_avg     => $raw{CANCEL_TIMES}->@*  ? sprintf("%.0f", List::Util::sum($raw{CANCEL_TIMES}->@*) / $raw{CANCEL_TIMES}->@*)   : undef,
        buy_completion_rate => $raw{BUY_COMPLETION}->@*
        ? sprintf("%.1f", (List::Util::sum($raw{BUY_COMPLETION}->@*) / $raw{BUY_COMPLETION}->@*) * 100)
        : undef,
        sell_completion_rate => $raw{SELL_COMPLETION}->@*
        ? sprintf("%.1f", (List::Util::sum($raw{SELL_COMPLETION}->@*) / $raw{SELL_COMPLETION}->@*) * 100)
        : undef,
        advert_rates => $raw{ADVERT_RATES}->@* ? sprintf("%.2f", (List::Util::sum($raw{ADVERT_RATES}->@*) / $raw{ADVERT_RATES}->@*) * 100)
        : undef,
        partner_count => $redis->scard($key_prefix . 'ORDER_PARTNERS'),
    };

    return $stats;
}

=head2 _p2p_advertiser_online_status

Gets online status of an advertiser.

Takes the following arguments:

=over 4

=item * C<$loginid> - loginid of advertiser

=back

Returns hash of fields that can be used directly in responses.

=cut

sub _p2p_advertiser_online_status {
    my ($self, $loginid, $country) = @_;

    my $last_online = BOM::Config::Redis->redis_p2p->zscore(P2P_USERS_ONLINE_KEY, ($loginid . "::" . $country));

    return (
        is_online        => ($last_online and $last_online >= (time - P2P_ONLINE_PERIOD)) ? 1 : 0,
        last_online_time => $last_online,
    );
}

=head2 _p2p_advertiser_relation_lists

Get all P2P advertiser relations of current user.

=cut

sub _p2p_advertiser_relation_lists {
    my ($self) = @_;

    my $advertiser = $self->_p2p_advertiser_cached or return;

    my $relations = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM p2p.advertiser_relation_list(?)', {Slice => {}}, $advertiser->{id});
        });

    my $lists;
    for my $rel (@$relations) {
        push $lists->{$rel->{relation_type}}->@*,
            {
            created_time => Date::Utility->new($rel->{created_time})->epoch,
            id           => $rel->{relation_id},
            name         => $rel->{relation_name},
            };
    }

    return {
        favourite_advertisers => $lists->{favourite} // [],
        blocked_advertisers   => $lists->{block}     // []};
}

=head2 _p2p_order_buy_confirmed

Called when order is buy confirmed by client as $self.

Takes the following argument:

=over 4

=item * C<order> - result of p2p.order_confirm* db function as hashref.

=back

=cut

sub _p2p_order_buy_confirmed {
    my ($self, $order) = @_;

    # for calculating release times
    my $redis = BOM::Config::Redis->redis_p2p_write();
    $redis->hset(P2P_STATS_REDIS_PREFIX . '::BUY_CONFIRM_TIMES', $order->{id}, time);
    return;
}

=head2 _p2p_order_completed

Called when an order is completed as a result of seller confirmation.
Not called for disputes.

Takes the following argument:

=over 4

=item * C<order> - order hashref

=back

=cut

sub _p2p_order_completed {
    my ($self, $order) = @_;

    my ($buyer, $seller) = $self->_p2p_order_parties($order);
    my $redis = BOM::Config::Redis->redis_p2p();
    my ($id, $amount) = $order->@{qw/id amount/};

    $self->_p2p_record_stat(
        loginid => $buyer,
        stat    => 'BUY_COMPLETED',
        payload => [$id, $amount]);

    $self->_p2p_record_stat(
        loginid => $seller,
        stat    => 'SELL_COMPLETED',
        payload => [$id, $amount]);

    $self->_p2p_record_stat(
        loginid => $buyer,
        stat    => 'BUY_COMPLETION',
        payload => [$id, 1]);

    $self->_p2p_record_stat(
        loginid => $seller,
        stat    => 'SELL_COMPLETION',
        payload => [$id, 1]);
    $redis->hincrby(P2P_STATS_REDIS_PREFIX . '::TOTAL_COMPLETED', $buyer,  1);
    $redis->hincrby(P2P_STATS_REDIS_PREFIX . '::TOTAL_COMPLETED', $seller, 1);
    $redis->hincrbyfloat(P2P_STATS_REDIS_PREFIX . '::TOTAL_TURNOVER', $buyer,  $amount);
    $redis->hincrbyfloat(P2P_STATS_REDIS_PREFIX . '::TOTAL_TURNOVER', $seller, $amount);
    $redis->zadd(P2P_ORDER_REVIEWABLE_START_AT, time, $id . '|' . $buyer, time, $id . '|' . $seller);
    $self->_p2p_record_partners($order);

    if (my $buy_confirm_epoch = $redis->hget(P2P_STATS_REDIS_PREFIX . '::BUY_CONFIRM_TIMES', $id)) {

        # only record buy and release time if there is no dispute
        unless ($order->{disputer_loginid}) {
            # this buy time assumes buyer actually paid when buyer clicked "I've paid"
            my $buy_time     = $buy_confirm_epoch - Date::Utility->new($order->{created_time})->epoch;
            my $release_time = time - $buy_confirm_epoch;
            $self->_p2p_record_stat(
                loginid => $buyer,
                stat    => 'BUY_TIMES',
                payload => [$id, $buy_time],
                ts      => $buy_confirm_epoch    # ts: stat occurrence will be time buyer clicked "I've paid", not now
            );
            $self->_p2p_record_stat(
                loginid => $seller,
                stat    => 'RELEASE_TIMES',
                payload => [$id, $release_time]);
        }

        # clean up
        $redis->hdel(P2P_STATS_REDIS_PREFIX . '::BUY_CONFIRM_TIMES', $id);
    }

    for my $loginid ($buyer, $seller) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $loginid,
            });
    }

    # only update the seller's ads, the buyer event is triggered by the transaction
    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $order->{type} eq 'sell' ? $order->{client_id} : $order->{advertiser_id},
        });

    return;
}

=head2 _p2p_order_cancelled

Called when an order is cancelled manually or expires while pending.
If beyond the grace period, will increment buyer's cancel count.
Will set temporary bar if on the buyer if cancel limit is exceeded.

Takes the following argument:

=over 4

=item * C<order> - order hashref

=back

=cut

sub _p2p_order_cancelled {
    my ($self, $order) = @_;

    my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $redis  = BOM::Config::Redis->redis_p2p_write();
    my $id     = $order->{id};

    my $elapsed = time - Date::Utility->new($order->{created_time})->epoch;

    # config period is minutes
    return if $elapsed < ($config->cancellation_grace_period * 60);

    my ($buyer_loginid) = $self->_p2p_order_parties($order);
    # make sure we are operating on the buyer - bom-events will use client_loginid of the order, which is not always buyer

    my $buyer_client = $buyer_loginid eq $self->loginid ? $self : $self->client->get_client_instance($buyer_loginid, 'write', $self->{context});

    $buyer_client->_p2p_record_stat(
        loginid => $buyer_loginid,
        stat    => 'ORDER_CANCELLED',
        payload => [$id, $order->{amount}]);
    $buyer_client->_p2p_record_stat(
        loginid => $buyer_loginid,
        stat    => 'BUY_COMPLETION',
        payload => [$id, 0]);

    # manual cancellation
    if ($order->{status} eq 'cancelled') {
        $buyer_client->_p2p_record_stat(
            loginid => $buyer_loginid,
            stat    => 'CANCEL_TIMES',
            payload => [$id, $elapsed]);
    }

    my $buyer_advertiser = $buyer_client->_p2p_advertisers(loginid => $buyer_loginid)->[0] // return;
    return if $buyer_client->_p2p_get_advertiser_bar_error($buyer_advertiser);
    my $cancellations = $buyer_client->_p2p_advertiser_cancellations;

    if ($cancellations->{remaining} == 0) {
        my $block_time = Date::Utility->new->plus_time_interval($config->cancellation_barring->bar_time . 'h');
        $buyer_client->db->dbic->run(
            fixup => sub {
                $_->do(
                    'SELECT p2p.advertiser_update_v2(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, NULL, NULL)',
                    undef, $buyer_advertiser->{id},
                    $block_time->datetime
                );
            });

        # used in p2p daemon to push a p2p_advertiser_info message
        $redis->zadd(P2P_ADVERTISER_BLOCK_ENDS_AT, $block_time->epoch, $buyer_loginid);

        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_temp_banned => {
                loginid        => $buyer_loginid,
                order_id       => $order->{id},
                limit          => $cancellations->{limit},
                block_end_date => $block_time->date,
                block_end_time => $block_time->time_hhmm,

            });
    } else {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_cancel_at_fault => {
                loginid           => $buyer_loginid,
                order_id          => $order->{id},
                cancels_remaining => $cancellations->{remaining},
            });
    }

    return;
}

=head2 _p2p_order_finalized

Called when an order enters final status for any reason.
For cleanup etc.

Takes the following argument:

=over 4

=item * C<order> - order hashref

=back

=cut

sub _p2p_order_finalized {
    my ($self, $order) = @_;
    my $order_id = $order->{id};
    my $redis    = BOM::Config::Redis->redis_p2p_write;

    my @order_keys = map { $order_id . "|" . $_ } $order->@{qw/client_loginid advertiser_loginid/};
    $redis->hdel(P2P_ORDER_LAST_SEEN_STATUS, @order_keys);

    $redis->del(P2P_VERIFICATION_ATTEMPT_KEY . "::$order_id", P2P_VERIFICATION_HISTORY_KEY . "::$order_id");
}

=head2 _p2p_advertiser_cancellations

Returns a hashref containing:

=over 4

=item *  C<remaining> - remaining cancellations allowed for a client

=item *  C<limit> - current cancellation limit

=back

=cut

sub _p2p_advertiser_cancellations {

    my ($self) = @_;
    my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;

    # config period is hours
    my ($period, $limit) = ($config->cancellation_barring->period, $config->cancellation_barring->count);
    my $stats = $self->_p2p_advertiser_stats($self->loginid, $period);

    return {
        remaining => max($limit - $stats->{cancel_count}, 0),
        limit     => $limit,
    };
}

=head2 _p2p_get_advertiser_bar_error

Returns error message for temporary block, or nothing if not blocked.

=cut

sub _p2p_get_advertiser_bar_error {
    my ($self, $advertiser) = @_;

    my $blocked_until = $advertiser->{blocked_until} // return;

    return +{
        error_code     => 'TemporaryBar',
        message_params => [$blocked_until],
        }
        if Date::Utility->new->is_before(Date::Utility->new($blocked_until));
}

=head2 _p2p_order_fraud

Called when an order dispute is resolved as a fraud case.
May disable the advertiser.

Takes the following arguments:

=over 4

=item * Ctype> - type of fraud: buy or sell

=item * C<order> - order hashref

=back

=cut

sub _p2p_order_fraud {
    my ($self, $type, $order) = @_;

    my $redis = BOM::Config::Redis->redis_p2p();
    my ($buyer, $seller) = $self->_p2p_order_parties($order);
    my $loginid = $type eq 'buy' ? $buyer : $seller;

    # Fraud stats are lifetime, so are not added in the usual way
    my $item = join '|',  $order->@{qw/id amount/};
    my $key  = join '::', P2P_STATS_REDIS_PREFIX, $loginid, uc($type) . '_FRAUD';
    $redis->zadd($key, time, $item);

    my $advertiser = $self->_p2p_advertisers(loginid => $loginid)->[0] // return;
    my $config     = BOM::Config::Runtime->instance->app_config->payments->p2p->fraud_blocking;
    my ($period_cfg, $count_cfg) = ($type . '_period', $type . '_count');

    # config period is days, stats are hours
    my $stats = $self->_p2p_advertiser_stats($loginid, $config->$period_cfg * 24);

    if ($stats->{$type . '_fraud_count'} >= $config->$count_cfg) {
        # disable the advertiser
        $self->db->dbic->run(
            fixup => sub {
                $_->do('SELECT p2p.advertiser_update_v2(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL)',
                    undef, $advertiser->{id});
            });
    }

    return;
}

=head2 _p2p_order_parties

Determinine buyer and seller for an order.

Takes the following argument:

=over 4

=item * C<order> - order hashref

=back

Returns array of loginids: (buyer, seller)

=cut

sub _p2p_order_parties {
    my ($self, $order) = @_;

    my $buyer  = $order->{type} eq 'buy'  ? $order->{client_loginid} : $order->{advertiser_loginid};
    my $seller = $order->{type} eq 'sell' ? $order->{client_loginid} : $order->{advertiser_loginid};
    return ($buyer, $seller);
}

=head2 p2p_order_status_history

Get the list of status changes of the specified order.

Note the list is in chronologically ascending order.

Note the list never returns two consecutive repeated status.

The hashref keys for each status change is described as follow:

=over 4

=item * stamp, the timestamp of the status

=item * status, the updated status

=back

It takes the following parameters:

=over 4

=item * order_id, the id of the order

=back

Returns,
    a ref to the list described.

=cut

sub p2p_order_status_history {
    my ($self, $order_id) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM p2p.order_status_history(?)', {Slice => {}}, $order_id);
        }) // [];
}

=head2 p2p_payment_methods

Returns P2P payment methods optionally filtered by availability in a country.

The payment_method_countries config (json) is set in backoffice. Each method has 2 keys in the config:
    - countries: list of 2 digit country codes
    - mode: include or exclude - controls if method is included or excluded in the country list

Returns hashref compatible with websocket schema.

Takes the following arguments:

=over 4

=item * country: if not provided all pms are returned

=back

=cut

sub p2p_payment_methods {
    my ($self, $country) = @_;

    my $methods        = $self->_p2p_payment_methods_cached;
    my $country_config = $self->_payment_method_countries_cached;
    my $result         = {};

    for my $method (keys %$methods) {
        my $config    = $country_config->{$method} // {};
        my $mode      = $config->{mode}            // 'include';
        my $countries = $config->{countries}       // [];

        next if $country and $mode eq 'include' and none { $_ eq $country } @$countries;
        next if $country and $mode eq 'exclude' and any { $_ eq $country } @$countries;

        my $method_def = $methods->{$method};
        my %fields     = map {
            $_ => {
                display_name => localize($method_def->{fields}{$_}{display_name}),
                type         => $method_def->{fields}{$_}{type}     // 'text',
                required     => $method_def->{fields}{$_}{required} // 1,
            }
        } keys $method_def->{fields}->%*;

        # this field is needed for all methods
        $fields{instructions} = {
            display_name => localize('Instructions'),
            type         => 'memo',
            required     => 0,
        };

        $result->{$method} = {
            display_name => localize($method_def->{display_name}),
            type         => $method_def->{type},
            fields       => \%fields,
        };
    }

    return $result;
}

=head2 filter_ad_payment_methods

Filters disabled payment methods from an advert's payment_method_names field.
Used when we don't/can't send country_payment_methods param to p2p.advert_list db function.

=over 4

=item * ad: advert as returned from p2p.advert_list()

=back

Returns modified ad.

=cut

sub filter_ad_payment_methods {
    my ($self, $ad) = @_;

    my @my_pms         = keys $self->p2p_payment_methods($self->residence)->%*;
    my @advertiser_pms = keys $self->p2p_payment_methods($ad->{country})->%*;
    my @ad_pms         = ($ad->{payment_method_names} // [])->@*;
    my @valid_pms      = intersect(@my_pms, @advertiser_pms);
    $ad->{payment_method_names} = [intersect(@ad_pms, @valid_pms)];

    return $ad;
}

=head2 p2p_advertiser_payment_methods

Sets and returns advertiser payment methods.

Takes the following named parameters, all optional:

=over 4

=item * create: arrayref of items to create

=item * update: hashref of items to update

=item * delete: arrayref of items to delete

=back

Returns hashref compatible with websocket schema.

=cut

sub p2p_advertiser_payment_methods {
    my ($self, %param) = @_;

    my $advertiser = $self->_p2p_advertiser_cached;
    die +{error_code => 'AdvertiserNotRegistered'} unless $advertiser;

    $self->set_db('write') if %param && $self->get_db ne 'write';
    my $existing = $self->_p2p_advertiser_payment_methods(advertiser_id => $advertiser->{id});

    delete $param{p2p_advertiser_payment_methods};
    return $self->_p2p_advertiser_payment_method_details($existing) unless %param;

    die +{error_code => 'PaymentMethodsDisabled'}
        unless BOM::Config::Runtime->instance->app_config->payments->p2p->payment_methods_enabled;

    $existing = $self->_p2p_advertiser_payment_method_delete($existing, $param{delete}) if $param{delete};
    $existing = $self->_p2p_advertiser_payment_method_update($existing, $param{update}) if $param{update};
    $self->_p2p_advertiser_payment_method_create($existing, $param{create}) if $param{create};

    BOM::Platform::Event::Emitter::emit(
        p2p_adverts_updated => {
            advertiser_id => $advertiser->{id},
        }) if $param{delete} or $param{update};

    my $update = $self->_p2p_advertiser_payment_methods(advertiser_id => $advertiser->{id});
    return $self->_p2p_advertiser_payment_method_details($update);
}

=head2 _p2p_advertiser_payment_method_delete

Deletes advertiser payment methods.

Takes the following parameters:

=over 4

=item * existing: hashref of existing methods

=item * deletes: arrayref of ids to delete

=back

Returns $existing with deleted items removed.

=cut

sub _p2p_advertiser_payment_method_delete {
    my ($self, $existing, $deletes) = @_;

    for my $id (@$deletes) {
        die +{error_code => 'PaymentMethodNotFound'} unless delete $existing->{$id};
    }

    $self->_p2p_check_payment_methods_in_use($deletes);

    $self->db->dbic->run(
        fixup => sub {
            $_->do('SELECT p2p.advertiser_payment_method_delete(?)', undef, $deletes);
        });

    return $existing;
}

=head2 _p2p_advertiser_payment_method_update

Updates advertiser payment methods.

Takes the following parameters:

=over 4

=item * existing: hashref of existing methods

=item * updates: hashref of items to update

=back

Returns $existing with updated items.

=cut

sub _p2p_advertiser_payment_method_update {
    my ($self, $existing, $updates) = @_;
    my $pm_defs = $self->p2p_payment_methods();    # pm can be updated after being disabled in country
    my (@disabled_ids, @updated_ids);
    my $old_pm_details = {};

    $self->set_db('replica');
    for my $id (keys %$updates) {
        die +{error_code => 'PaymentMethodNotFound'} unless exists $existing->{$id};

        my $method   = $existing->{$id}{method};
        my $pm_def   = $pm_defs->{$method};
        my %combined = ($existing->{$id}{fields}->%*, $updates->{$id}->%*);
        # we need to combine fields from $existing and $updates to do proper validation for:
        # (1) MissingPaymentMethodField: If API users omit a required field (which was previously optional) during pm update, we still need to flag it as: MISSING REQUIRED FIELD
        # (2) DuplicatePaymentMethod: For existing duplicate pms, if user omit required fields and updates any optional field, we need to flag it as DUPLICATE PM

        for my $item_field (grep { $_ ne 'is_enabled' } keys %combined) {
            my $field_def = $pm_def->{fields}{$item_field};
            die +{
                error_code     => 'InvalidPaymentMethodField',
                message_params => [$item_field, $pm_def->{display_name}]}
                unless $field_def;

            die +{
                error_code     => 'MissingPaymentMethodField',
                message_params => [$field_def->{display_name}, $pm_def->{display_name}]}
                if $field_def->{required} and not(trim($combined{$item_field}));

            $old_pm_details->{$id}{fields}{$item_field} = ($existing->{$id}{fields}{$item_field} // '');
            $existing->{$id}{fields}{$item_field}       = $combined{$item_field};
        }

        $self->_p2p_validate_other_pm($combined{name}) if $method eq 'other';

        my %required = map { $pm_def->{fields}{$_}{required} ? ($_ => $combined{$_}) : () } keys $pm_def->{fields}->%*;

        # If there are no required fields for a particular pm, we don't need to check for duplicates
        # without this check, we will get a false positive for DuplicatePaymentMethod error
        if (my @keys = keys %required) {
            for my $pm_id (keys %$existing) {
                next if $pm_id == $id or ($existing->{$pm_id}->{method} ne $method);
                my $other_pm = $existing->{$pm_id};

                next unless all { lc($other_pm->{fields}{$_}) eq lc($existing->{$id}{fields}{$_}) } @keys;
                die +{
                    error_code     => 'DuplicatePaymentMethod',
                    message_params => [$pm_def ? $pm_def->{display_name} : $method]};
            }

            if (any { $combined{$_} ne ($old_pm_details->{$id}{fields}{$_} // '') } keys $updates->{$id}->%*) {
                $self->_p2p_is_pm_global_duplicate($method, \%required, $pm_def->{display_name});
            }
        }

        push(@disabled_ids, $id) if exists $updates->{$id}{is_enabled} and (!$updates->{$id}{is_enabled}) and $existing->{$id}{is_enabled};
        push(@updated_ids,  $id);
    }

    $self->set_db('write');
    $self->_p2p_check_payment_methods_in_use(\@disabled_ids, \@updated_ids);

    $self->db->dbic->run(
        fixup => sub {
            $_->do('SELECT p2p.advertiser_payment_method_update(?)', undef, Encode::encode_utf8(encode_json_utf8($updates)));
        });

    return $existing;
}

=head2 _p2p_advertiser_payment_method_create

Creates advertiser payment methods.

Takes the following parameters:

=over 4

=item * existing: hashref of existing methods

=item * updates: hashref of items to create

=back

Returns undef.

=cut

sub _p2p_advertiser_payment_method_create {
    my ($self, $existing, $new) = @_;
    my $pm_defs  = $self->p2p_payment_methods($self->residence);
    my $dummy_id = 0;

    $self->set_db('replica');
    for my $item (@$new) {
        my $method = $item->{method};

        die +{
            error_code     => 'InvalidPaymentMethod',
            message_params => [$method]}
            unless exists $pm_defs->{$method};

        my $method_def = $pm_defs->{$method};

        for my $item_field (grep { $_ !~ /^(method|is_enabled)$/ } keys %$item) {
            die +{
                error_code     => 'InvalidPaymentMethodField',
                message_params => [$item_field, $method_def->{display_name}]}
                unless exists $method_def->{fields}{$item_field};
        }
        my %required = ();
        for my $field (keys $method_def->{fields}->%*) {
            next if $field =~ /^(method|is_enabled)$/;
            next unless $method_def->{fields}{$field}{required};
            if (!trim($item->{$field})) {
                die +{
                    error_code     => 'MissingPaymentMethodField',
                    message_params => [$method_def->{fields}{$field}{display_name}, $method_def->{display_name}]};
            }
            $required{$field} = $item->{$field};
        }

        $self->_p2p_validate_other_pm($item->{name}, $pm_defs) if $method eq 'other';

        if (my @keys = keys %required) {
            for my $existing_pm (values %$existing) {
                next if $existing_pm->{method} ne $method;
                next unless all { lc $item->{$_} eq lc($existing_pm->{fields}{$_} // '') } @keys;
                die +{
                    error_code     => 'DuplicatePaymentMethod',
                    message_params => [$method_def->{display_name}]};
            }
            $self->_p2p_is_pm_global_duplicate($method, \%required, $method_def->{display_name});

            # try to detect duplicates within same call for existing pms
            $existing->{--$dummy_id} = {
                method => $method,
                fields => {pairgrep { $required{$a} } %$item}};
        }
    }

    $self->set_db('write');
    for my $item (@$new) {
        my $created_pm = $self->db->dbic->run(
            fixup => sub {
                my $dbh = shift;
                return $dbh->selectrow_hashref(
                    'SELECT * FROM p2p.advertiser_payment_method_create_v2(?, ?)',
                    undef,
                    $self->_p2p_advertiser_cached->{id},
                    Encode::encode_utf8(encode_json_utf8($item)));
            });

        if ($created_pm->{error_params}->[0]) {
            $created_pm->{error_params}->[0] = $pm_defs->{$item->{method}}{display_name};
        }

        $self->_p2p_db_error_handler($created_pm);
    }

    return;
}

=head2 _p2p_validate_other_pm

Check if name given for OTHER payment method (pm) contains any keywords/name of ewallets/bank_transfer supported in P2P.

=over 4

=item * $name: user input for name of OTHER pm

=item * $pm_keywords: list of keywords/name (listed in p2p_payment_methods.yml) of pms available in advertiser's country

=back

Dies or returns undef.

=cut

sub _p2p_validate_other_pm {
    my ($self, $name, $country_pm_def) = @_;
    my $pms = $self->_p2p_payment_methods_cached;

    $country_pm_def //= $self->p2p_payment_methods($self->residence);
    $pms = +{pairgrep { $country_pm_def->{$a} } %$pms};
    delete $pms->@{qw(other bank_transfer)};
    # other pm is excluded from this check as the name is very generic
    # bank is excluded as there are other ewallet pm that contains the word: 'bank'

    # if advertiser's input contains keywords of PM that's disabled/unavailable in his country, this check will not apply
    my @pm_keywords = map { $pms->{$_}{keywords} ? $pms->{$_}{keywords}->@* : ($_ =~ s/_//gr) } keys %$pms;
    my $cleaned     = lc($name =~ s/[^a-zA-Z]//gr);

    if (any { length($_) > 3 && index($cleaned, $_) != -1 } @pm_keywords) {

        die +{
            error_code     => 'InvalidOtherPaymentMethodName',
            message_params => [$name]};
    }
}

=head2 _p2p_is_pm_global_duplicate

Check if payment method (pm) details provided are already in use by another advertiser

=over 4

=item * $method: name of pm for internal use (keys in p2p_payment_methods.yml)

=item * $required_params: key-value pair where the keys are required fields of a particular pm

=item * $display_name: name of pm we show to client (display_name in p2p_payment_methods.yml)

=back

Dies or returns undef.

=cut

sub _p2p_is_pm_global_duplicate {
    my ($self, $method, $required_params, $display_name) = @_;

    my ($duplicate_pm_exist) = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_array(
                'SELECT * FROM p2p.check_duplicate_payment_method(?,?,?)', undef,
                $self->_p2p_advertiser_cached->{id},                       $method,
                Encode::encode_utf8(encode_json_utf8($required_params)));
        });

    die +{
        error_code     => 'PaymentMethodInfoAlreadyInUse',
        message_params => [$display_name]} if $duplicate_pm_exist;
}

=head2 _p2p_check_payment_methods_in_use

Validates that payment methods can be deactivated or deleted.

=over 4

=item * $deleted_ids: payment method ids to be deleted or deactivated

=item * $updated_ids: payment method ids to be updated

=back

Dies or returns undef.

=cut

sub _p2p_check_payment_methods_in_use {
    my ($self, $deleted_ids, $updated_ids) = @_;

    my $in_use = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM p2p.advertiser_payment_method_in_use(?, ?)', {Slice => {}}, $deleted_ids, $updated_ids);
        });

    return unless @$in_use;

    die +{
        error_code     => 'PaymentMethodUsedByAd',
        message_params => [join ', ', $in_use->[0]{advert_ids}->@*],
        }
        unless grep { $_->{order_ids} } @$in_use;

    die +{
        error_code     => 'PaymentMethodUsedByOrder',
        message_params => [join ', ', $in_use->[0]{order_ids}->@*],
        }
        unless grep { $_->{advert_ids} } @$in_use;

    die +{error_code => 'PaymentMethodInUse'};
}

=head2 _p2p_db_error_handler

Maping db p2p error code to rpc error code 

=over 4

=item * $err_code: error code which comes from db

=item * $err_params: parameters which use in error message  

=back

Dies or returns undef.

=cut

sub _p2p_db_error_handler {
    my ($self, $p2p_object) = @_;

    unless ($p2p_object->{error_code}) {
        delete $p2p_object->@{qw(error_params error_code)};
        return;
    }

    die +{
        error_code => P2P_DB_ERR_MAP->{$p2p_object->{error_code}},
        $p2p_object->{error_params} ? (message_params => $p2p_object->{error_params}) : (),
    };
}

=head2 p2p_balance

Returns the balance available for p2p

=cut

sub p2p_balance {
    my ($self) = @_;

    my $account_balance = $self->account->balance;
    my $excluded_amount = $self->p2p_exclusion_amount;
    my $advertiser      = $self->_p2p_advertiser_cached    // {};
    my $extra_sell      = $advertiser->{extra_sell_amount} // 0;
    my $p2p_balance     = min($account_balance, max(0, $account_balance - $excluded_amount) + $extra_sell);

    return financialrounding('amount', $self->currency, $p2p_balance);
}

=head2 p2p_exclusion_amount

Returns the amount that must be excluded from a P2P advertiser's account balance.

=cut

sub p2p_exclusion_amount {
    my ($self) = @_;

    my ($reversible, $limit, $lookback);
    my @restricted_countries = BOM::Config::Runtime->instance->app_config->payments->p2p->fiat_deposit_restricted_countries->@*;

    if (any { $self->residence eq $_ } @restricted_countries) {
        $limit      = 0;
        $lookback   = BOM::Config::Runtime->instance->app_config->payments->p2p->fiat_deposit_restricted_lookback;
        $reversible = 0;
    } else {
        $limit      = BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p / 100;
        $lookback   = BOM::Config::Runtime->instance->app_config->payments->reversible_deposits_lookback;
        $reversible = 1;
    }

    my ($amount) = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM p2p.balance_exclusion_amount(?, ?, ?, ?)', undef, $self->account->id, $limit, $lookback, $reversible);
        });

    return $amount;
}

=head2 p2p_withdrawable_balance

Returns the amount that can be withdrawn via cashier or transferred to sibling accounts.

=cut

sub p2p_withdrawable_balance {
    my ($self) = @_;

    my $balance = $self->account->balance;
    my $config  = BOM::Config::Runtime->instance->app_config->payments;
    my $limit   = $config->p2p_withdrawal_limit;                          # this setting is a percentage

    if ($limit >= 100 || $self->p2p_is_advertiser_blocked || !BOM::Config::P2P::available_countries()->{$self->residence}) {
        return $balance;
        # permanently banned P2P advertiser or advertisers from P2P banned countries can withdraw p2p deposits
    }

    my $lookback = $config->p2p_deposits_lookback;

    my ($p2p_net) = $self->db->dbic->run(
        fixup => sub {
            return $_->selectrow_array('SELECT payment.aggregate_payments_by_type(?, ?, ?)', undef, $self->account->id, 'p2p', $lookback);
        }) // 0;

    return $balance if $p2p_net <= 0;
    $p2p_net = $p2p_net * (1 - ($limit / 100));
    my $p2p_excluded = $self->p2p_exclusion_amount;

    # this calcalution was tested on over 10k clients so even though it may look strange, we know it works
    return min($balance, $p2p_excluded + max(0, $balance - $p2p_excluded - $p2p_net));
}

=head2 p2p_country_list

Returns P2P Country and their configuration including availaible paymment methods.

Takes the following arguments:

=over 4

=item * country: if not provided all countries are returned

=back

=cut

sub p2p_country_list {
    my ($self, %param) = @_;

    my $target_country = $param{country};

    my $app_config    = BOM::Config::Runtime->instance->app_config;
    my $p2p_config    = $app_config->payments->p2p;
    my $advert_config = $self->_advert_config_cached();

    my $all_countries = BOM::Config::P2P::available_countries();

    die +{error_code => 'RestrictedCountry'} if ($target_country and not $all_countries->{$target_country});

    my $countries = {};

    for my $country (keys $all_countries->%*) {
        next if $target_country and $target_country ne $country;

        $countries->{$country}{country_name}    = $all_countries->{$country};
        $countries->{$country}{payment_methods} = $self->p2p_payment_methods($country);

        my $local_currency = BOM::Config::CurrencyConfig::local_currency_for_country(country => $country);
        $countries->{$country}{local_currency} = $local_currency;

        $countries->{$country}{float_rate_offset_limit} =
            Math::BigFloat->new(BOM::Config::P2P::currency_float_range($local_currency))->bdiv(2)->bfround(-2, 'trunc')->bstr;

        $countries->{$country}{cross_border_ads_enabled} =
            (any { lc($_) eq $country } $p2p_config->cross_border_ads_restricted_countries->@*) ? 0 : 1;

        $countries->{$country}{fixed_rate_adverts} = $advert_config->{$country}{fixed_ads};
        $countries->{$country}{float_rate_adverts} = $advert_config->{$country}{float_ads};
    }

    return $countries;
}

=head2 _p2p_payment_methods_cached

Cache of p2p payment methods for the current client.

In tests you will need to delete this every time you update an payment methods and call another RPC method.

=cut

sub _p2p_payment_methods_cached {
    my $self = shift;

    return $self->{_p2p_payment_methods_cached} //= BOM::Config::p2p_payment_methods();
}

=head2 _payment_method_countries_cached

Cache of p2p payment method and their countries the current client.

=cut

sub _payment_method_countries_cached {
    my $self = shift;

    return $self->{_payment_method_countries_cached} //=
        decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->p2p->payment_method_countries());
}

=head2 _advert_config_cached

Cache of BOM::Config::P2P::advert_config for the current instance

=cut

sub _advert_config_cached {
    my $self = shift;

    return $self->{_advert_config_cached} //= BOM::Config::P2P::advert_config();
}

#### TODO: As Bill Marriott suggesting below functions should remove and use $p2p->client->sub_call explicity everywhere!

sub broker_code {
    my $self = shift;
    return $self->{client}->{broker_code};
}

sub loginid {
    my $self = shift;
    return $self->{client}->{loginid};
}

sub residence {
    my $self = shift;
    return $self->{client}->residence;
}

sub currency {
    my $self = shift;
    return $self->{client}->currency;
}

sub local_currency {
    my $self = shift;
    return $self->{client}->local_currency;
}

sub client {
    my $self = shift;
    return $self->{client};
}

sub status {
    my $self = shift;
    return $self->{client}->status;
}

sub account {
    my $self = shift;
    return $self->{client}->account;
}

sub email {
    my $self = shift;
    return $self->{client}->email;
}

sub db {
    my $self = shift;
    return $self->{client}->db;
}

sub get_db {
    my $self = shift;
    return $self->{client}->get_db;
}

sub set_db {
    my $self  = shift;
    my $param = shift;
    return $self->{client}->set_db($param);
}

sub first_name {
    my $self = shift;
    return $self->{client}->first_name;
}

sub binary_user_id {
    my $self = shift;
    return $self->{client}->binary_user_id;
}

sub broker {
    my $self = shift;
    return $self->{client}->broker;
}

sub user {
    my $self = shift;
    return $self->{client}->user;
}
1;
