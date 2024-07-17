#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use BOM::User::Client;
use BOM::User::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::P2P::BOUtility;
use Format::Util::Numbers qw(financialrounding);
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);
use List::Util   qw(min max first any uniq);
use Data::Dumper;
use DateTime;
use DateTime::Format::Pg;
use DateTime::TimeZone;
use Date::Utility;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any        qw($log);

use constant {
    P2P_ADVERTISER_BLOCK_ENDS_AT        => 'P2P::ADVERTISER::BLOCK_ENDS_AT',
    P2P_ONLINE_PERIOD                   => 90,
    P2P_ADVERTISER_BAND_UPGRADE_PENDING => 'P2P::ADVERTISER_BAND_UPGRADE_PENDING',
};

my $cgi         = CGI->new;
my $is_readonly = BOM::Backoffice::Auth::has_readonly_access();
code_exit_BO(_get_display_error_message("Access Denied: you do not have access to make this change"))
    if $is_readonly and request()->http_method eq 'POST';
PrintContentType();
try { BrokerPresentation(' '); }
catch { }
Bar('P2P Advertiser Management');

my %input  = %{request()->params};
my $broker = request()->broker_code;
my %output;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

$output{can_set_band}     = BOM::Backoffice::Auth::has_authorisation(['P2PAdmin', 'AntiFraud']);
$output{can_edit_general} = $output{can_set_band} || BOM::Backoffice::Auth::has_authorisation(['P2PRead', 'P2PWrite']);

if ($input{create}) {
    try {
        my $client = BOM::User::Client->new({loginid => $input{new_loginid}});
        $client->p2p_advertiser_create(name => $input{new_name});
        $output{message} = $input{new_loginid} . ' has been registered as P2P advertiser.';
    } catch ($err) {
        $Data::Dumper::Terse = 1;
        $output{error} = $input{new_loginid} . ' could not be registered as a P2P advertiser: ' . (ref($err) ? Dumper($err) : $err);
    }
}

if (my $id = $input{update}) {
    try {
        my $id = $input{update_id} or die "Invalid params\n";

        die "You do not have permission to set band level\n" if !$output{can_set_band} && $input{trade_band};

        my $existing = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM p2p.advertiser_list_v2(?,NULL,NULL,NULL,NULL)', undef, $id);
            });

        if ($output{can_edit_general}) {

            if (($input{current_name} // '') ne ($input{update_name} // '')) {
                my ($dupe_name) = $db->run(
                    fixup => sub {
                        $_->selectrow_array('SELECT * FROM p2p.advertiser_list_v2(NULL,NULL,NULL,?,NULL) WHERE id != ?',
                            undef, $input{update_name}, $id);
                    });

                die "There is already another advertiser with this nickname\n" if $dupe_name;
            }

            if ($input{blocked_until}) {
                try {
                    my $dt = DateTime::Format::Pg->parse_datetime($input{blocked_until});
                    Date::Utility->new($dt->ymd);
                    #previous line is added to make sure exception is thrown for futuristic date like '3000-02-27' which is not detected otherwise
                    #DateTime::Format::Pg->parse_datetime is still retained because it's better at parsing different types of date input
                    $input{blocked_until} = DateTime::Format::Pg->format_datetime($dt);
                } catch {
                    die "Invalid date format\n";
                }
            }

            my $update = $db->run(
                fixup => sub {
                    $_->selectrow_hashref(
                        'SELECT * FROM p2p.advertiser_update_v2(?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, NULL)',
                        undef,
                        @input{
                            qw(update_id is_listed update_name default_advert_description payment_info contact_info trade_band is_enabled blocked_until show_name)
                        });
                });
            die "Invalid advertiser ID\n" unless $update;

            my $redis = BOM::Config::Redis->redis_p2p_write();

            # if user was eligible for a band upgrade before this change, will delete his field in redis
            $redis->hdel(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $id) if $input{trade_band} && ($existing->{trade_band} ne $input{trade_band});

            if (my $blocked_until = $update->{blocked_until}) {
                my $blocked_du_epoch = DateTime::Format::Pg->parse_datetime($blocked_until)->epoch;
                if ($blocked_du_epoch > time) {
                    $redis->zadd(P2P_ADVERTISER_BLOCK_ENDS_AT, $blocked_du_epoch, $existing->{client_loginid});
                }
            } else {
                $redis->zrem(P2P_ADVERTISER_BLOCK_ENDS_AT, $existing->{client_loginid});
            }

            if (($input{current_name} // '') ne ($input{update_name} // '')) {
                my $sendbird_api = BOM::User::Utility::sendbird_api();
                WebService::SendBird::User->new(
                    user_id    => $existing->{chat_user_id},
                    api_client => $sendbird_api
                )->update(nickname => $input{update_name});
            }
        }

        my ($extra_sell, $extra_sell_orig) = @input{qw(extra_sell_amount current_extra_sell_amount)};
        die "Invalid Additional sell allowance value\n" unless looks_like_number($extra_sell) and $extra_sell >= 0;
        if (looks_like_number($extra_sell_orig) and $extra_sell != $extra_sell_orig) {
            die "Additional sell allowance has changed while the page was open, please try again.\n"
                if $extra_sell_orig != ($existing->{extra_sell_amount} // 0);

            $db->run(
                fixup => sub {
                    $_->do('SELECT p2p.set_advertiser_totals(?, NULL, NULL, NULL, ?)', undef, $id, $extra_sell);
                });
        }

        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $existing->{client_loginid},
            },
        );

        BOM::Platform::Event::Emitter::emit(
            p2p_adverts_updated => {
                advertiser_id => $id,
            });

        $output{message} = "Advertiser $id details saved.";

    } catch ($err) {
        $Data::Dumper::Terse = 1;
        $output{error} = 'Could not update P2P advertiser: ' . (ref($err) ? Dumper($err) : $err);
    }
}

!$input{$_} && delete $input{$_} for qw(loginID name);
$input{loginID} = trim uc $input{loginID} if $input{loginID};
delete $input{id}                         if defined($input{id})   && $input{id}   !~ m/^[0-9]+$/;
delete $input{days}                       if defined($input{days}) && $input{days} !~ m/^[0-9]+$/;
$output{days}        = defined($input{days}) ? $input{days} : 30;
$output{is_readonly} = $is_readonly;

if ($input{loginID} || $input{name} || $input{id}) {
    $output{advertiser} = $db->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.advertiser_list_v2(?,?,NULL,?,NULL)', undef, @input{qw/id loginID name/});
        });
    $output{error} //= 'Advertiser not found' unless $output{advertiser};
}

if ($output{advertiser}) {

    my $loginid = $output{advertiser}->{client_loginid};
    my $client  = BOM::User::Client->new({loginid => $loginid});
    $output{stats} = $client->_p2p_advertiser_stats($loginid, $output{days} * 24);

    my $online_ts = $output{stats}->{last_online};
    $output{advertiser}->{is_online}   = ($online_ts and $online_ts >= (time - P2P_ONLINE_PERIOD)) ? '&#128994;' : '&#9711;';
    $output{advertiser}->{online_time} = $online_ts ? Date::Utility->new($online_ts)->db_timestamp               : '>6 months';

    for (qw/cancel_time_avg release_time_avg/) {
        $output{stats}{$_} = int($output{stats}{$_} / 60) . 'm ' . ($output{stats}{$_} % 60) . 's' if defined $output{stats}{$_};
    }

    $output{relations} = $client->_p2p_advertiser_relation_lists;
    $output{advertiser}{total_completion_rate} =
        $output{advertiser}{completion_rate} ? sprintf("%.1f", $output{advertiser}{completion_rate} * 100) : undef;

    $output{payment_methods} = $client->p2p_advertiser_payment_methods;

    my $db_ads = $client->_p2p_adverts(
        advertiser_id => $output{advertiser}->{id},
        show_deleted  => 1
    );
    my $ads = $client->_advert_details($db_ads);
    for my $ad (@$ads) {
        $ad->{is_deleted} = (first { $ad->{id} == $_->{id} } @$db_ads)->{is_deleted};
        $ad->{$_} = $ad->{$_} ? '&#9989;' : '&#10060;' for qw(is_deleted is_active is_visible);
    }

    # pagination
    my $page_size = 30;
    my $start     = $input{start} // 0;
    $output{prev}  = max(($start - $page_size), 0) if $start;
    $output{next}  = $start + $page_size           if @$ads > $start + $page_size;
    $output{range} = ($start + 1) . '-' . min(($start + $page_size), scalar @$ads) . ' of ' . (scalar @$ads);
    $output{ads}   = [splice(@$ads, $start, $page_size)];

    if (my $schedule = $output{advertiser}->{schedule}) {
        try {
            for my $country (sort { $a cmp $b } uniq($output{advertiser}->{country}, BOM::Backoffice::Utility::get_office_countries())) {
                push $output{timezones}->@*, map { [$_, $country] } DateTime::TimeZone->names_in_country($country);
            }

            my $offset;
            if ($input{tz} && $input{tz} ne 'UST') {
                my $tz = DateTime::TimeZone->new(name => $input{tz});
                $offset = $tz->offset_for_datetime(DateTime->now());
                $output{timezone_offset} = sprintf('%+d', $offset / 3600);
            }

            $output{schedule} = BOM::P2P::BOUtility::format_schedule($schedule, $offset);
        } catch ($e) {
            $log->warnf('error processing audit schedule data of advertiser %s: %s', $output{advertiser}->{id}, $e);
        }
    }

    $output{audit} = $db->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM p2p.advertiser_audit_history(?)', {Slice => {}}, $output{advertiser}->{id});
        });

    $_->{stamp} = Date::Utility->new($_->{stamp})->datetime for $output{audit}->@*;

    my $method_defs = BOM::Config::p2p_payment_methods();    ## todo: use P2P::_p2p_payment_methods_cached

    for my $update ($output{audit}->@*) {
        if ($update->{field} eq 'Payment Method') {
            for my $k (grep { $update->{$_} } qw(new_value old_value)) {
                try {
                    my $pm     = decode_json_utf8($update->{$k});
                    my $method = delete $pm->{method};
                    my $def    = $method_defs->{$method} // {};
                    $update->{$k}             = {method => $def->{display_name} // $method};
                    $update->{$k}{is_enabled} = delete $pm->{is_enabled};
                    $update->{$k}{params}     = {map { $def->{fields}{$_}{display_name} // $_ => $pm->{$_} } keys %$pm};
                } catch ($e) {
                    $log->warnf('error processing audit payment method data of advertiser %s: %s', $output{advertiser}->{id}, $e);
                }
            }
        }

        if ($update->{field} eq 'Schedule') {
            for my $k (grep { $update->{$_} } qw(new_value old_value)) {
                try {
                    $update->{$k} = BOM::P2P::BOUtility::format_schedule($update->{$k});
                } catch ($e) {
                    $log->warnf('error processing audit schedule data of advertiser %s: %s', $output{advertiser}->{id}, $e);
                }
            }
        }
    }

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $output{p2p_config} = $app_config->payments->p2p;

    my $bands = $db->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT DISTINCT(trade_band) FROM p2p.p2p_country_trade_band WHERE country = ? OR country = 'default'",
                undef, $output{advertiser}->{country});
        });
    $output{bands}                = [map { $_->[0] } @$bands];
    $output{p2p_balance}          = $client->p2p_balance;
    $output{balance_exclusion}    = min($client->p2p_exclusion_amount, $client->account->balance);
    $output{withdrawable_balance} = $client->p2p_withdrawable_balance;

    my @restricted_countries = $app_config->payments->p2p->fiat_deposit_restricted_countries->@*;
    if (any { $client->residence eq $_ } @restricted_countries) {
        $output{exclusion_criteria} = '100% of doughflow deposits in past ' . $app_config->payments->p2p->fiat_deposit_restricted_lookback . ' days';
    } else {
        my $limit = 100 - $app_config->payments->reversible_balance_limits->p2p;
        $output{exclusion_criteria} = $limit . '% of reversible deposits in past ' . $app_config->payments->reversible_deposits_lookback . ' days';
    }

    $output{age_verification}      = $client->status->age_verification;
    $output{not_approved_statuses} = [qw/cashier_locked disabled unwelcome duplicate_account withdrawal_locked no_withdrawal_or_trading/];
    $output{not_approved_by} =
        [grep { $client->status->$_(); } $output{not_approved_statuses}->@*];

    $output{rating} =
        $output{advertiser}->{rating_average}
        ? 'Average ' . sprintf('%.2f', $output{advertiser}->{rating_average}) . ' (' . $output{advertiser}->{rating_count} . ' ratings)'
        : 'no reviews yet';
    $output{recommend} =
        $output{advertiser}->{recommended_average}
        ? 'Average '
        . sprintf('%.1f', $output{advertiser}->{recommended_average} * 100) . '% ('
        . $output{advertiser}->{recommended_count}
        . ' users)'
        : 'no recommentations yet';

    if (my $band_upgrade = BOM::Config::Redis->redis_p2p->hget(P2P_ADVERTISER_BAND_UPGRADE_PENDING, $output{advertiser}->{id})) {
        try {
            $output{band_upgrade} = decode_json_utf8($band_upgrade);
        } catch {
            $output{error} = 'Invalid pending upgrade JSON stored for advertiser ' . $output{advertiser}->{id} . '. Please inform backend team.';
        }
    }

    if (my $blocked_until = $output{advertiser}->{blocked_until}) {
        $output{advertiser}->{barred} = DateTime::Format::Pg->parse_datetime($blocked_until)->epoch > time;
    }

    for (qw/daily_buy daily_sell withdrawal_limit extra_sell_pending/) {
        $output{$_ . '_formatted'} = financialrounding('amount', $output{advertiser}->{account_currency}, $output{advertiser}->{$_})
            if defined $output{advertiser}->{$_};
    }

    $output{extra_sell_amount_formatted} =
        financialrounding('amount', $output{advertiser}->{account_currency}, $output{advertiser}->{extra_sell_amount} // 0);

    $output{advertiser}->{$_} =
        defined $output{advertiser}->{$_}
        ? $output{advertiser}->{limit_currency} . ' ' . financialrounding('amount', $output{advertiser}->{limit_currency}, $output{advertiser}->{$_})
        : '-'
        for (qw/daily_buy_limit daily_sell_limit min_order_amount max_order_amount min_balance/);

    $output{$_ . '_formatted'} = financialrounding('amount', $output{advertiser}->{account_currency}, $output{$_})
        for qw(balance_exclusion withdrawable_balance);

} elsif ($input{loginID}) {
    try {
        local $SIG{__WARN__} = sub { };
        $output{client} = BOM::User::Client->new({loginid => $input{loginID}});
    } catch {
    }
    $output{error} = 'No such client: ' . $input{loginID} unless $output{client};
}

BOM::Backoffice::Request::template()->process('backoffice/p2p/p2p_advertiser_manage.tt', \%output);

code_exit_BO();
