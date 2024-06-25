package BOM::User::Script::P2PDailyMaintenance;

use strict;
use warnings;

use Business::Config::LandingCompany::Registry;

use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;
use Business::Config::Account::Type::Registry;
use Data::Chronicle::Reader;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use Cache::RedisDB;
use Quant::Framework;
use Finance::Exchange;
use LandingCompany::Registry;
use BOM::User::Utility;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Date::Utility;
use List::Util      qw(uniq sum);
use JSON::MaybeUTF8 qw(:v1);
use Brands;
use POSIX                      qw(ceil strftime);
use DataDog::DogStatsd::Helper qw(stats_timing);
use Time::HiRes;
use Format::Util::Numbers qw(formatnumber);

use constant {
    CRON_INTERVAL_DAYS                    => 1,
    AD_ARCHIVE_KEY                        => 'P2P::AD_ARCHIVAL_DATES',
    AD_ACTIVATION_KEY                     => 'P2P::AD_ACTIVATION',
    P2P_USERS_ONLINE_KEY                  => 'P2P::USERS_ONLINE',
    MAX_QUOTE_HOURS                       => 24,
    P2P_ONLINE_USER_PRUNE                 => 26 * 7 * 24 * 60 * 60,                      # 26 weeks
    DAILY_TOTALS_PRUNE_DAYS               => 60,
    P2P_STATS_REDIS_PREFIX                => 'P2P::ADVERTISER_STATS',
    P2P_ADVERTISER_BAND_UPGRADE_PENDING   => 'P2P::ADVERTISER_BAND_UPGRADE_PENDING',
    P2P_ADVERTISER_BAND_UPGRADE_COMPLETED => 'P2P::ADVERTISER_BAND_UPGRADE_COMPLETED',
    P2P_ADVERTISER_MIN_JOINED_DAYS        => 30,
};

=head1 Name

P2PDailyMaintenance - daily P2P housekpeeing tasks

=cut

=head2 new

Constructor.

=cut

sub new {
    return bless {}, shift;
}

=head2 run

Script entry point.

=cut

sub run {
    $log->debug("P2PDailyMaintenance running");

    my $brand             = Brands->new;
    my $redis             = BOM::Config::Redis->redis_p2p_write();
    my $app_config        = BOM::Config::Runtime->instance->app_config;
    my $archive_days      = $app_config->payments->p2p->archive_ads_days;
    my $delete_days       = $app_config->payments->p2p->delete_ads_days;
    my $all_countries     = $brand->countries_instance->countries_list;
    my $ad_config         = decode_json_utf8($app_config->payments->p2p->country_advert_config);
    my $campaigns         = decode_json_utf8($app_config->payments->p2p->email_campaign_ids);
    my $withdrawal_limits = Business::Config::LandingCompany::Registry->new()->payment_limit()->{withdrawal_limits};
    my %bo_activation     = $redis->hgetall(AD_ACTIVATION_KEY)->@*;
    my $now               = Date::Utility->new;
    my @advertiser_ids;    # for advertisers who had updated ads
    my %archival_dates;
    my %brokers;

    # P2P works on legacy accounts at the moment.
    # TODO: we should include `p2p` as well, when the appstore is going to launch on wallets.
    my $p2p_account_type = Business::Config::Account::Type::Registry->new()->account_type_by_name('binary');

    for my $lc (grep { $_->p2p_available } LandingCompany::Registry::get_all) {
        for my $broker ($p2p_account_type->broker_codes->{$lc->short}->@*) {
            $brokers{$broker} = {
                db_write => BOM::Database::ClientDB->new({
                        broker_code => uc $broker,
                        operation   => 'write'
                    }
                ),
                db_replica => BOM::Database::ClientDB->new({
                        broker_code => uc $broker,
                        operation   => 'replica'
                    }
                ),
                lc => $lc->short,
            };
        }
    }

    for my $broker (keys %brokers) {

        my $db_write   = $brokers{$broker}->{db_write}->db->dbic;
        my $db_replica = $brokers{$broker}->{db_replica}->db->dbic;
        my $lc         = $brokers{$broker}->{lc};

        try {

            # 1. archive inactive ads
            if ($archive_days > 0) {
                my $updates = $db_write->run(
                    fixup => sub {
                        $_->selectall_arrayref('SELECT * FROM p2p.deactivate_old_ads(?)', {Slice => {}}, $archive_days);
                    });

                my $archived_ads = {};

                for ($updates->@*) {
                    my ($id, $advertiser_loginid, $advertiser_id, $archive_date, $is_archived) =
                        @{$_}{qw/id advertiser_loginid advertiser_id archive_date is_archived/};
                    $archival_dates{$id} = $archive_date;

                    if ($is_archived) {
                        push $archived_ads->{$advertiser_loginid}->@*, $id;
                        push @advertiser_ids,                          $advertiser_id;
                    }
                }

                for my $login (keys $archived_ads->%*) {
                    BOM::Platform::Event::Emitter::emit(
                        'p2p_archived_ad',
                        {
                            archived_ads       => [sort $archived_ads->{$login}->@*],
                            advertiser_loginid => $login,
                        });
                }
            }

        } catch ($e) {
            $log->warnf('Error archiving ads for broker %s: %s', $broker, $e);
        }

        # 2. deactivate fixed/float rate ads
        for my $country (sort keys %$ad_config) {
            next unless $all_countries->{$country}{financial_company} eq $lc or $all_countries->{$country}{gaming_company} eq $lc;

            my %ads_to_deactivate;
            my $config = $ad_config->{$country};

            if ($config->{fixed_ads} ne 'disabled' and $config->{deactivate_fixed}) {
                my $deactivation_date = Date::Utility->new($config->{deactivate_fixed});

                if ($deactivation_date->is_after($now) and $bo_activation{"$country:deactivate_fixed"}) {

                    try {
                        my $campaign_id = $campaigns->{float_rate_notice} or die "float_rate_notice email campaign ID is undefined\n";

                        my $user_ids = $db_write->run(    # even though we are not updating any rows, PG won't allow us to use readonly connection :(
                            fixup => sub {
                                $_->selectcol_arrayref('SELECT binary_user_id FROM p2p.deactivate_ad_rate_types(?, ?, ?)',
                                    undef, ['fixed'], $country, 1);    # dry run
                            });

                        my @notification_users = uniq(@$user_ids);
                        $log->debugf('creating rate change notification for %i users in country %s', scalar(@notification_users), $country);

                        BOM::Platform::Event::Emitter::emit(
                            'trigger_cio_broadcast' => {
                                campaign_id       => $campaign_id,
                                ids               => \@notification_users,
                                id_ignore_missing => 1,
                                data              => {
                                    deactivation_date => $deactivation_date->date,
                                    local_currency    => BOM::Config::CurrencyConfig::local_currency_for_country(country => $country),
                                    live_chat_url     => $brand->live_chat_url,
                                }}) if @$user_ids;

                        $redis->hdel(AD_ACTIVATION_KEY, "$country:deactivate_fixed");

                    } catch ($e) {
                        $log->warnf('Error creating rate change notification for country %s: %s', $country, $e);
                    }
                }

                if ($deactivation_date->is_before($now)) {
                    $log->debugf('disabling fixed rates in country %s because deactivation date is set to %s', $country, $deactivation_date->date);
                    $app_config->chronicle_writer(BOM::Config::Chronicle::get_audited_chronicle_writer('P2P Daily Maintenance'));
                    $config->{fixed_ads} = 'disabled';
                    $app_config->set({'payments.p2p.country_advert_config' => encode_json_utf8($ad_config)});
                    $ads_to_deactivate{fixed} = 1;
                }
            }

            $ads_to_deactivate{fixed} = 1 if ($bo_activation{"$country:fixed_ads"} // '') eq 'disabled';
            $ads_to_deactivate{float} = 1 if ($bo_activation{"$country:float_ads"} // '') eq 'disabled';

            if (%ads_to_deactivate) {
                $log->debugf('disabling %s ads in country %s', [keys %ads_to_deactivate], $country);

                my $ads;
                try {
                    $ads = $db_write->run(
                        fixup => sub {
                            $_->selectall_hashref(
                                'SELECT binary_user_id, rate_type, advertiser_id FROM p2p.deactivate_ad_rate_types(?, ?, ?)',
                                ['rate_type', 'binary_user_id'],
                                undef,    [keys %ads_to_deactivate],
                                $country, 0                            # no dry run
                            );
                        });

                } catch ($e) {
                    $log->warnf('Error deactivating %s ads for country %s: %s', [keys %ads_to_deactivate], $country, $e);
                    next;
                }

                for my $type ('fixed', 'float') {
                    if ($ads->{$type}) {
                        my $key = $type . '_rate_disabled';

                        if (my $campaign_id = $campaigns->{$key}) {
                            BOM::Platform::Event::Emitter::emit(
                                'trigger_cio_broadcast' => {
                                    campaign_id       => $campaign_id,
                                    ids               => [keys $ads->{$type}->%*],
                                    id_ignore_missing => 1,
                                    data              => {
                                        local_currency => BOM::Config::CurrencyConfig::local_currency_for_country(country => $country),
                                        live_chat_url  => $brand->live_chat_url,
                                    }});
                        } else {
                            $log->warnf('%s email campaign ID is undefined', $key);
                        }

                        push @advertiser_ids, map { $_->{advertiser_id} } values $ads->{$type}->%*;
                    }
                }

                $redis->hdel(AD_ACTIVATION_KEY, "$country:fixed_ads", "$country:float_ads");
            }
        }

        my %advertiser_updates;

        # 3. get advertiser completion rates to update
        try {

            my $rows = $db_replica->run(
                fixup => sub {
                    $_->selectall_hashref('SELECT * FROM p2p.get_advertiser_completion(?)', 'advertiser_id', {Slice => {}}, CRON_INTERVAL_DAYS);
                });

            for my $advertiser (keys %$rows) {
                $advertiser_updates{$advertiser}{$_} = $rows->{$advertiser}{$_} for keys $rows->{$advertiser}->%*;
            }

        } catch ($e) {
            $log->warnf('Error refreshing advertiser completion rates for broker %s: %s', $broker, $e);
        }

        # 4. get advertiser withdrawal limits to update
        try {
            if (my $limit = $withdrawal_limits->{$lc}) {
                my $rows = $db_replica->run(
                    fixup => sub {
                        $_->selectall_hashref(
                            'SELECT * FROM p2p.get_advertiser_withdrawal_limits(?, NULL, ?)',
                            'advertiser_id',
                            {Slice => {}},
                            $limit->{lifetime_limit},
                            CRON_INTERVAL_DAYS
                        );
                    });

                for my $advertiser (keys %$rows) {
                    $advertiser_updates{$advertiser}{$_} = $rows->{$advertiser}{$_} for keys $rows->{$advertiser}->%*;
                }
            }
        } catch ($e) {
            $log->errorf('Error populating withdrawal limits for broker %s: %s', $broker, $e);
        }

        # 5. update advertiser totals
        for my $update (values %advertiser_updates) {
            try {
                $db_write->run(
                    fixup => sub {
                        $_->do('SELECT p2p.set_advertiser_totals(?, ?, ?, ?)',
                            undef, $update->@{qw(advertiser_id complete_total complete_success withdrawal_limit)});
                    });
            } catch ($e) {
                $log->errorf('Error saving totals for %s: %s', $update, $e);
            }
        }

        # 6. delete old daily totals
        try {
            $db_write->run(
                fixup => sub {
                    $_->do('SELECT p2p.prune_daily_totals(?)', undef, DAILY_TOTALS_PRUNE_DAYS);
                });
        } catch ($e) {
            $log->errorf('Error pruning daily totals %s: %s', $broker, $e);
        }

        # 7. check if active P2P advertisers eligible for limit increase
        try {
            my $start_time  = Time::HiRes::time;
            my $db_upgrades = $db_replica->run(
                fixup => sub {
                    $_->selectall_arrayref('SELECT * FROM p2p.advertisers_for_band_upgrade_v2(?,NULL)', {Slice => {}},
                        P2P_ADVERTISER_MIN_JOINED_DAYS);
                });
            stats_timing('p2p.advertisers_for_band_upgrade.timing', (Time::HiRes::time - $start_time) * 1000);

            my %advertiser_upgrades;
            for my $upgrade (@$db_upgrades) {
                my $id = $upgrade->{id};

                # find total lifetime fraud for that advertiser (cached in $advertiser_upgrades{$id})
                $upgrade->{fraud_count} = $advertiser_upgrades{$id}->{fraud_count} //=
                    sum(map { $redis->zcard(join '::' => P2P_STATS_REDIS_PREFIX, $upgrade->{client_loginid}, $_) } qw{BUY_FRAUD SELL_FRAUD});

                next if $advertiser_upgrades{$id}->{fraud_count} > ($upgrade->{max_allowed_fraud_cases} // 0);
                next if $advertiser_upgrades{$id}->{block_trade} && !$upgrade->{block_trade};
                next if ($advertiser_upgrades{$id}->{target_total} // 0) >= $upgrade->{target_total};

                $advertiser_upgrades{$id} = $upgrade;
            }

            $redis->del(P2P_ADVERTISER_BAND_UPGRADE_PENDING);

            for my $upgrade (values %advertiser_upgrades) {
                next unless $upgrade->{target_trade_band};

                # if automatic upgrade, send tracking event, otherwise store in redis
                if ($upgrade->{automatic_approve}) {
                    $log->debugf('Automatically upgrading advertiser %s (%s) to %s band', $upgrade->@{qw(id client_loginid target_trade_band)});

                    $db_write->run(
                        fixup => sub {
                            $_->do(
                                'SELECT p2p.advertiser_update_v2(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, NULL, NULL, NULL, NULL)',
                                undef, $upgrade->@{qw(id target_trade_band)});

                        });

                    # trigger customer.io email and mobile PN for automatically approved limit upgrade
                    # currently only medium band fall under this category but this might change in future
                    BOM::Platform::Event::Emitter::emit(
                        p2p_limit_changed => {
                            loginid           => $upgrade->{client_loginid},
                            advertiser_id     => $upgrade->{id},
                            new_sell_limit    => formatnumber('amount', $upgrade->{account_currency}, $upgrade->{target_max_daily_sell}),
                            new_buy_limit     => formatnumber('amount', $upgrade->{account_currency}, $upgrade->{target_max_daily_buy}),
                            block_trade       => $upgrade->{target_block_trade},
                            account_currency  => $upgrade->{account_currency},
                            change            => 1,
                            automatic_approve => 1,

                        });

                } else {
                    $log->debugf('Advertiser %s (%s) is eligible to upgrade to band %s', $upgrade->@{qw(id client_loginid target_trade_band)});

                    my %pending_data = map { $_ => $upgrade->{$_} } qw(client_loginid account_currency email_alert_required
                        target_trade_band target_max_daily_sell target_max_daily_buy target_block_trade target_band_country
                        old_trade_band old_band_country completed_orders fraud_count fully_authenticated days_since_joined turnover payment_agent_tier);
                    $pending_data{$_} = sprintf("%.3f", $upgrade->{$_}) for grep { defined $upgrade->{$_} } qw(completion_rate dispute_rate);
                    $redis->hset(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $upgrade->{id}, encode_json_utf8(\%pending_data));

                    # trigger customer.io mobile PN to notify user he/she is eligible for limit upgrade
                    BOM::Platform::Event::Emitter::emit(
                        p2p_limit_upgrade_available => {
                            loginid       => $upgrade->{client_loginid},
                            advertiser_id => $upgrade->{id},
                        });
                }
                # this event is to send updated advertiser info only to that specific advertiser
                BOM::Platform::Event::Emitter::emit(
                    p2p_advertiser_updated => {
                        client_loginid => $upgrade->{client_loginid},
                        self_only      => 1,
                    },
                );
            }
        } catch ($e) {
            $log->errorf('Error checking P2P advertisers eligibility for limit increase %s: %s', $broker, $e);
        }

        #8. Delete old ads
        if ($delete_days > 0) {
            try {
                $db_write->run(
                    fixup => sub {
                        $_->do('SELECT p2p.delete_old_ads(?)', undef, $delete_days);
                    });
            } catch ($e) {
                $log->errorf('Error deleting old ads for broker %s: %s', $broker, $e);
            }
        }

    }

    $redis->multi;
    $redis->del(AD_ARCHIVE_KEY);
    $redis->hset(AD_ARCHIVE_KEY, $_, $archival_dates{$_}) for keys %archival_dates;
    $redis->expire(AD_ARCHIVE_KEY, $archive_days * 24 * 60 * 60);
    $redis->exec;

    # 9. delete very old user online activity records
    $redis->zremrangebyscore(P2P_USERS_ONLINE_KEY, '-Inf', time - P2P_ONLINE_USER_PRUNE);

    for my $advertiser_id (uniq @advertiser_ids) {
        BOM::Platform::Event::Emitter::emit(
            'p2p_adverts_updated' => {
                advertiser_id => $advertiser_id,
            });
    }

    my $chronicle_reader = Data::Chronicle::Reader->new(cache_reader => Cache::RedisDB::redis());
    my $trading_calendar = Quant::Framework->new->trading_calendar($chronicle_reader);
    my $exchange         = Finance::Exchange->create_exchange('FOREX');
    my %all_currencies   = %BOM::Config::CurrencyConfig::ALL_CURRENCIES;

    # 10. send internal email if any floating rate countries have exchange rates older than MAX_QUOTE_SECS
    my @alerts;

    for my $currency (keys %all_currencies) {
        my @float_countries = grep { $ad_config->{$_} and $ad_config->{$_}{float_ads} ne 'disabled' } $all_currencies{$currency}->{countries}->@*;
        next unless @float_countries;

        my $rate = BOM::User::Utility::p2p_exchange_rate($currency);

        unless (defined $rate->{quote}) {
            push @alerts,
                {
                currency  => $currency,
                countries => \@float_countries,
                age_hours => 'inf'
                };
            next;
        }
        my $date      = Date::Utility->new($rate->{epoch});
        my $diff_days = $now->days_between($date);
        my $age_hours = 50 * 24;

        # seconds_of_trading_between_epochs() has deep recursion error with big date intervals
        if ($diff_days < 50) {
            my $age_sec = $trading_calendar->seconds_of_trading_between_epochs($exchange, $date, Date::Utility->new);
            $age_hours = ceil($age_sec / 60);
        }

        push @alerts,
            {
            %$rate,
            currency  => $currency,
            countries => \@float_countries,
            age_hours => $age_hours,
            date      => $date,
            }
            if $age_hours > MAX_QUOTE_HOURS;
    }

    if (@alerts) {
        $log->debugf('sending quants email for %i alerts', scalar @alerts);

        my @lines = (
            '<p>The following currency(s) have countries with floating rate adverts enabled in P2P, and the FOREX market has been open more than 24 hours since the exchange rate was updated.<br>Actions needed:</p>',
            '<ul><li>Check the feed</li><li>Enter a manual quote in backoffice P2P advert rates management</li><li>Consider switching the countries to fixed rate adverts</li></ul>',
            '<table border=1 style="border-collapse:collapse;"><tr><th>Currency</th><th>Age (hours)</th><th>Source</th><th>Time</th><th>Quote</th><th>Float rate country(s)</th></tr>',
        );

        for my $alert (sort { $b->{age_hours} <=> $a->{age_hours} } @alerts) {
            push @lines, '<tr><td>' . $alert->{currency} . ' (' . $all_currencies{$alert->{currency}}->{name} . ')</td>';
            if ($alert->{quote}) {
                push @lines,
                    (
                    '<td>' . ($alert->{age_hours} == 50 * 24 ? 'more than ' : '') . $alert->{age_hours} . '</td>',
                    '<td>' . $alert->{source} . '</td>',
                    '<td>' . $alert->{date}->datetime . '</td>',
                    '<td>' . $alert->{quote} . '</td>',
                    );
            } else {
                push @lines, '<td colspan=4>No rate</td>';
            }
            push @lines, '<td>' . (join '<br>', map { $_ . ' (' . $all_countries->{$_}{name} . ')' } $alert->{countries}->@*) . '</td></tr>';
        }
        push @lines, '</table>';

        send_email({
                from                  => 'x-backend@binary.com',
                to                    => 'x-p2p-system-notifications@binary.com',
                subject               => 'Outdated exchange rates for P2P Float Rate countries on ' . $now->date,
                email_content_is_html => 1,
                message               => \@lines,
            }) or $log->warn('Failed to send outdated exchange rates alert email to p2p team');

    }

    # 11. send email to anti-fraud team for each successful P2P band upgrade that has flag (email_alert_required:1)
    if (my %completed_upgrades = $redis->hgetall(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED)->@*) {
        my @lines = (
            '<p>The following P2P advertiser(s) have upgraded their P2P Band limit in the last 24 hours:<br></p>',
            '<p>Completed Orders, Completion Rate and Dispute Rate are statistics for the last one month.<br></p>',
            '<table border=1 cellpadding="3" style="border-collapse:collapse;"><tr>',
            '<th>Advertiser ID</th><th>Loginid</th><th>Currency</th><th>Country</th><th>Upgrade Time</th>',
            '<th>Old Band</th><th>Old Sell Limit</th><th>Old Buy Limit</th><th>Old Block Trade</th><th>Old Band Country</th>',
            '<th>New Band</th><th>New Sell Limit</th><th>New Buy Limit</th><th>New Block Trade</th><th>New Band Country</th>',
            '<th>Completed Orders</th><th>Completion Rate</th><th>Dispute Rate</th><th>Fraud Count</th><th>POA</th>',
            '<th>Advertiser Tenure (Days)</th><th>30 day turnover</th><th>Payment Agent Tier</th></tr>',
        );

        my @fields = qw(client_loginid account_currency country upgrade_date
            old_trade_band old_sell_limit old_buy_limit old_block_trade old_band_country
            target_trade_band target_max_daily_sell target_max_daily_buy target_block_trade target_band_country
            completed_orders completion_rate dispute_rate fraud_count fully_authenticated days_since_joined turnover payment_agent_tier);

        for my $id (keys %completed_upgrades) {
            push @lines, '<tr><td style="padding:0px 10px 0px 10px">' . $id . '</td>';

            try {
                my $upgrade = decode_json_utf8($completed_upgrades{$id});
                $upgrade->{$_} = ($upgrade->{$_} ? 'yes' : 'no') for qw(old_block_trade target_block_trade fully_authenticated);
                $upgrade->{$_} = formatnumber('amount', $upgrade->{account_currency}, $upgrade->{$_} // 0)
                    for qw(target_max_daily_buy target_max_daily_sell turnover);
                $upgrade->{upgrade_date} = Date::Utility->new($upgrade->{upgrade_date})->datetime . ' GMT';
                push @lines, map { '<td style="padding:0px 10px 0px 10px">' . ($upgrade->{$_} // '') . '</td>' } @fields;
            } catch ($e) {
                push @lines, '<td colspan="' . (scalar @fields) . '">';
                push @lines, sprintf('Could not retrieve upgrade data from redis (%s): %s', $completed_upgrades{$id}, $e);
            }

            push @lines, '</tr>';
        }

        push @lines, '</table>';

        send_email({
                from                  => 'x-backend@binary.com',
                to                    => $brand->emails(q{anti-fraud}),
                subject               => 'P2P Band Upgrade list',
                email_content_is_html => 1,
                message               => \@lines,
            }) or $log->warn('Failed to send P2P Band Upgrade list to anti-fraud team');

        $redis->del(P2P_ADVERTISER_BAND_UPGRADE_COMPLETED);
    }

    return 0;
}

1;
