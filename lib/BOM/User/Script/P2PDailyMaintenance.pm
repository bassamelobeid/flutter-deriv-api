package BOM::User::Script::P2PDailyMaintenance;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;
use BOM::Config::AccountType::Registry;
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
use List::Util      qw(uniq);
use JSON::MaybeUTF8 qw(:v1);
use Brands;

use constant {
    CRON_INTERVAL_DAYS      => 1,
    AD_ARCHIVE_KEY          => 'P2P::AD_ARCHIVAL_DATES',
    AD_ACTIVATION_KEY       => 'P2P::AD_ACTIVATION',
    P2P_USERS_ONLINE_KEY    => 'P2P::USERS_ONLINE',
    MAX_QUOTE_SECS          => 24 * 60 * 60,               # 1 day
    P2P_ONLINE_USER_PRUNE   => 26 * 7 * 24 * 60 * 60,      # 26 weeks
    DAILY_TOTALS_PRUNE_DAYS => 60,
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

    my $brand             = Brands->new(name => 'deriv');                   # todo: replace with BOM::Config->brand when it is changed to Deriv
    my $redis             = BOM::Config::Redis->redis_p2p_write();
    my $app_config        = BOM::Config::Runtime->instance->app_config;
    my $archive_days      = $app_config->payments->p2p->archive_ads_days;
    my $all_countries     = $brand->countries_instance->countries_list;
    my $ad_config         = decode_json_utf8($app_config->payments->p2p->country_advert_config);
    my $campaigns         = decode_json_utf8($app_config->payments->p2p->email_campaign_ids);
    my $withdrawal_limits = BOM::Config::payment_limits()->{withdrawal_limits};
    my %bo_activation     = $redis->hgetall(AD_ACTIVATION_KEY)->@*;
    my $now               = Date::Utility->new;
    my @advertiser_ids;                                                     # for advertisers who had updated ads
    my %archival_dates;
    my %brokers;

    # P2P works on `binary` accounts at the moment.
    # TODO: we should include `wallet` as well, when the appstore is going to launch.
    my $account_category = BOM::Config::AccountType::Registry->category_by_name('binary');

    for my $lc (grep { $_->p2p_available } LandingCompany::Registry::get_all) {
        for my $broker ($account_category->broker_codes->{$lc->short}->@*) {
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
                                    local_currency    => BOM::Config::CurrencyConfig::local_currency_for_country($country),
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
                                        local_currency => BOM::Config::CurrencyConfig::local_currency_for_country($country),
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

    }

    $redis->multi;
    $redis->del(AD_ARCHIVE_KEY);
    $redis->hset(AD_ARCHIVE_KEY, $_, $archival_dates{$_}) for keys %archival_dates;
    $redis->expire(AD_ARCHIVE_KEY, $archive_days * 24 * 60 * 60);
    $redis->exec;

    # 7. delete very old user online activity records
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

    # 8. send internal email if any floating rate countries have exchange rates older than MAX_QUOTE_SECS
    my @alerts;
    for my $country (keys %$ad_config) {
        next if $ad_config->{$country}{float_ads} eq 'disabled';
        my $rate = BOM::User::Utility::p2p_exchange_rate($country);
        unless ($rate) {
            push @alerts,
                {
                country => $country,
                age     => "inf"
                };
            next;
        }
        my $date = Date::Utility->new($rate->{epoch});
        my $age  = $trading_calendar->seconds_of_trading_between_epochs($exchange, $date, Date::Utility->new);
        push @alerts,
            {
            %$rate,
            country => $country,
            age     => $age,
            date    => $date
            } if ($age > MAX_QUOTE_SECS);
    }

    if (@alerts) {
        $log->debugf('sending quants email for %i alerts', scalar @alerts);

        my @lines = (
            '<p>The following country(s) have floating rate adverts enabled in P2P, and the FOREX market has been open more than 24 hours since the exchange rate was updated.<br>Actions needed:</p>',
            '<ul><li>Check the feed</li><li>Enter a manual quote</li><li>Consider switching the country to fixed rate adverts</li></ul>',
            '<table border=1 style="border-collapse:collapse;"><tr><th>Country</th><th>Currency</th><th>Age (hours)</th><th>Source</th><th>Time</th><th>Quote</th></tr>',
        );

        for my $alert (sort { $b->{age} <=> $a->{age} } @alerts) {
            push @lines,
                (
                '<tr><td>' . $alert->{country} . ' (' . $all_countries->{$alert->{country}}{name} . ')</td>',
                '<td>' . BOM::Config::CurrencyConfig::local_currency_for_country($alert->{country}) . '</td>',
                );
            if ($alert->{quote}) {
                push @lines,
                    (
                    '<td>' . sprintf('%.1f', ($alert->{age} / 3600)) . '</td>',
                    '<td>' . $alert->{source} . '</td>',
                    '<td>' . $alert->{date}->datetime . '</td>',
                    '<td>' . $alert->{quote} . '</td></tr>',
                    );
            } else {
                push @lines, '<td colspan=4>No rate</td></tr>';
            }
        }
        push @lines, '</table>';

        send_email({
                from                  => 'x-backend@binary.com',
                to                    => 'x-trading-ops@deriv.com',
                subject               => 'Outdated exchange rates for P2P Float Rate countries on ' . $now->date,
                email_content_is_html => 1,
                message               => \@lines,
            }) or $log->warn('Failed to send rate alert email to quants');

    }

    return 0;
}

1;
