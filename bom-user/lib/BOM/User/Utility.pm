package BOM::User::Utility;

use 5.014;
use strict;
use warnings;

use feature qw(state);

use Crypt::CBC;
use Crypt::NamedKeys;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use DateTime;
use Date::Utility;
use Encode;
use Encode::Detect::Detector;
use Syntax::Keyword::Try;
use Email::Address::UseXS;
use Email::Stuffer;
use YAML::XS qw(LoadFile);
use Path::Tiny;
use Dir::Self;
use WebService::SendBird;
use JSON::MaybeUTF8 qw(:v1);
use Digest::SHA     qw(hmac_sha1_hex);
use List::Util      qw (any first uniq);
use POSIX           qw( floor );
use Math::BigFloat;
use JSON::MaybeXS;
use Text::Trim qw( trim );

use BOM::Platform::Context qw(request);
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;
use BOM::Config::P2P;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Locale;

use Exporter qw(import);
our @EXPORT_OK = qw(parse_mt5_group p2p_rate_rounding p2p_exchange_rate);

use constant {
    P2P_ADVERT_STATE_PREFIX => 'P2P::ADVERT_STATE::',    # p2p advert state storage
    P2P_ADVERT_STATE_EXPIRY => 7 * 24 * 60 * 60,         # 7 days
    P2P_RATE_PRECISION      => 6,
};

sub aes_keys {
    state $config = YAML::XS::LoadFile('/etc/rmg/aes_keys.yml');
    return $config;
}

sub encrypt_secret_answer {
    my $secret_answer = shift;
    return Crypt::NamedKeys->new(keyname => 'client_secret_answer')->encrypt_payload(data => $secret_answer);
}

sub decrypt_secret_answer {
    my $encoded_secret_answer = shift;

    return undef unless $encoded_secret_answer;

    my $secret_answer;
    try {
        if ($encoded_secret_answer =~ /^\w+\*.*\./) {    # new AES format
            $secret_answer = Crypt::NamedKeys->new(keyname => 'client_secret_answer')->decrypt_payload(value => $encoded_secret_answer);
        } elsif ($encoded_secret_answer =~ s/^::ecp::(\S+)$/$1/) {    # legacy blowfish
            my $cipher = Crypt::CBC->new({
                'key'    => aes_keys()->{client_secret_answer}->{1},
                'cipher' => 'Blowfish',
                'iv'     => aes_keys()->{client_secret_iv}->{1},
                'header' => 'randomiv',
            });

            $secret_answer = $cipher->decrypt_hex($encoded_secret_answer);
        } else {
            die "Invalid or outdated encrypted value.";
        }
    } catch ($e) {
        die "Not able to decode secret answer! $e";
    }

    return $secret_answer;
}

=head2 get_details_from_environment

Get details from environment, which includes the IP address, country, user agent, and the
device id.

=cut

sub get_details_from_environment {
    my $env = shift;

    return {} unless $env;

    # Take IP address first two octet
    my ($ip) = $env =~ /IP=(\d{1,3}\.\d{1,3})/i;

    my ($country) = $env =~ /IP_COUNTRY=(\w{1,2})/i;

    my ($user_agent) = $env =~ /(User_AGENT.+(?=\sLANG))/i;
    $user_agent =~ s/User_AGENT=//i if $user_agent;

    my ($device_id) = $env =~ /DEVICE_ID=(\w+)/i;

    return {
        ip         => $ip,
        country    => uc($country // 'unknown'),
        user_agent => $user_agent,
        device_id  => $device_id,
    };
}

=head2 login_details_identifier

Take an environment string from the "login_history" and return an identifier for this entry.

The identifier is a mix from the country, device (Android, Linux), and browser.

Device ID added if it present.

If one of these three pieces of information is missing it will be replaced with "unknown".

=cut

sub login_details_identifier {
    # This is a heavy module so we will only included it here
    require HTTP::BrowserDetect;

    my $enviroment_string = shift;
    return "" unless $enviroment_string;

    my $enviroment_details = get_details_from_environment($enviroment_string);

    my $country    = $enviroment_details->{'country'};
    my $user_agent = $enviroment_details->{'user_agent'};
    my $device_id  = $enviroment_details->{'device_id'};
    my $ip         = $enviroment_details->{'ip'};

    my $browser_info = HTTP::BrowserDetect->new($user_agent);

    my $device  = $browser_info->device || $browser_info->os_string || 'unknown';
    my $browser = $browser_info->browser_string || 'unknown';

    my $login_identifier = ($country || 'unknown') . '::' . $device . '::' . $browser;
    $login_identifier .= '::' . $ip        if $ip;
    $login_identifier .= '::' . $device_id if $device_id;

    return $login_identifier;
}

sub sendbird_api {
    my $config = BOM::Config::third_party()->{sendbird};

    return WebService::SendBird->new(
        api_token => $config->{api_token},
        app_id    => $config->{app_id},
    );
}

=head2 parse_mt5_group

Sample group: real\svg (old group name), real01\synthetic\svg_std_usd (new group name)

Returns

=over 4

=item * C<account_type> - real|demo

=item * C<server_type> - server id (E.g. 01, 02 ..)

=item * C<market_type> - financial|synthetic

=item * C<landing_company_short> - landing company short name (E.g. svg, malta ..)

=item * C<sub_account_type> - std|sf|stp

=item * C<currency> - group currency

=back

=cut

sub parse_mt5_group {
    my $group = shift;

    my ($account_type, $platform_type, $server_type, $market_type, $landing_company_short, $sub_account_type, $currency);

    # TODO (JB): remove old mt5 groups support when we have move all accounts over to the new groups
    # old mt5 groups support
    if ($group =~ m/^([a-z]+)\\([a-z]+)(?:_([a-z]+(?:_stp)?+))?(?:_([A-Z,a-z]+))?$/) {
        $account_type          = $1;
        $landing_company_short = $2;
        my $subtype = $3;
        $currency         = lc($4 // 'usd');
        $server_type      = '01';              # default to 01 for old group
        $market_type      = (not $subtype)                            ? 'synthetic' : 'financial';
        $sub_account_type = (defined $subtype and $subtype =~ /stp$/) ? 'stp'       : 'std';
    } elsif ($group =~ /^(real|demo)(?:\\p(\d{2})_ts)?(\d{2})\\(synthetic|financial|all)\\([a-z]+)_(.*)_(\w+)(?:\\\d{2})?$/) {
        $account_type          = $1;
        $platform_type         = $2;
        $server_type           = $3;
        $market_type           = $4;
        $landing_company_short = $5;
        $sub_account_type      = $6;
        $currency              = $7;
    }

    $platform_type //= '01';
    my $final_server_type = $server_type ? "p${platform_type}_ts${server_type}" : undef;

    return {
        account_type          => $account_type,
        server_type           => $final_server_type,
        market_type           => $market_type,
        landing_company_short => $landing_company_short,
        sub_account_type      => $sub_account_type,
        currency              => $currency,
    };
}

=head2 p2p_on_advert_view

Saves P2P advert states in redis and returns the ones that have changed.

=over

=item * C<$advertiser_id> - advertiser id - all ads must belong to a single advertiser

=item * C<data> - 2 dimensional hash of arrays, keyed by loginid of subscriber and advert id of subscripton (or 'ALL' for all ads)

=back

Returns $data with unchanged ads removed.

=cut

sub p2p_on_advert_view {
    my ($advertiser_id, $data) = @_;

    # client specific fields will be stored in redis as field/loginid. advertiser_ fields are ones that are within advertiser_details in the ad structure.
    my %fields = (
        common => [
            qw(order_expiry_period payment_method payment_method_names is_active local_currency rate min_order_amount_limit max_order_amount_limit rate_offset effective_rate min_completion_rate min_rating min_join_days eligible_countries)
        ],
        client => [
            qw(is_visible visibility_status payment_info contact_info active_orders amount remaining_amount min_order_amount max_order_amount is_eligible eligibility_status)
        ],
        advertiser_common => [qw(total_completion_rate rating_average recommended_average)],
        advertiser_client => [qw(is_favourite is_blocked is_recommended)],
    );

    my $p2p_redis    = BOM::Config::Redis->redis_p2p_write();
    my $key          = P2P_ADVERT_STATE_PREFIX . $advertiser_id;
    my $state        = decode_json_utf8($p2p_redis->get($key) // '{}');
    my @existing_ids = keys %$state;
    my ($updates, $new_state);

    for my $loginid (keys %$data) {
        for my $type (keys $data->{$loginid}->%*) {
            for my $new_ad ($data->{$loginid}{$type}->@*) {
                my $id = $new_ad->{id};

                if ($new_ad->{deleted}) {
                    push $updates->{$loginid}{$type}->@*,
                        {
                        id      => $id,
                        deleted => 1
                        };
                    delete $state->{$id};
                    next;
                }

                my %new_ad_copy;
                $new_ad_copy{$_} = $new_ad->{$_}                     // '' for ($fields{common}->@*,            $fields{client}->@*);
                $new_ad_copy{$_} = $new_ad->{advertiser_details}{$_} // '' for ($fields{advertiser_common}->@*, $fields{advertiser_client}->@*);
                $new_ad_copy{$_} = join(',', sort $new_ad_copy{$_}->@*) for grep { ref $new_ad_copy{$_} eq 'ARRAY' } keys %new_ad_copy;

                my $cur_ad = $state->{$id};

                if (   not $cur_ad
                    or any     { ($cur_ad->{$_}           // '') ne $new_ad_copy{$_} } ($fields{common}->@*, $fields{advertiser_common}->@*)
                        or any { ($cur_ad->{$_}{$loginid} // '') ne $new_ad_copy{$_} } ($fields{client}->@*, $fields{advertiser_client}->@*))
                {
                    push $updates->{$loginid}{$type}->@*, $new_ad;
                    $new_state->{$id}{$loginid} = \%new_ad_copy;
                }
            }

            # For ALL subscription, find deleted ads by comparing old state with new state
            if ($type eq 'ALL') {
                for my $id (@existing_ids) {
                    next if any { $_->{id} == $id } $data->{$loginid}{$type}->@*;
                    push $updates->{$loginid}{$type}->@*,
                        {
                        id      => $id,
                        deleted => 1
                        };
                    delete $state->{$id};
                }
            }
        }
    }

    for my $id (keys %$new_state) {
        for my $loginid (keys $new_state->{$id}->%*) {
            for my $field (keys $new_state->{$id}{$loginid}->%*) {
                my $val = $new_state->{$id}{$loginid}{$field};
                $state->{$id}{$field}           = $val if any { $_ eq $field } ($fields{common}->@*, $fields{advertiser_common}->@*);
                $state->{$id}{$field}{$loginid} = $val if any { $_ eq $field } ($fields{client}->@*, $fields{advertiser_client}->@*);
            }
        }
    }

    $p2p_redis->set($key, encode_json_utf8($state), 'EX', P2P_ADVERT_STATE_EXPIRY);
    return $updates;
}

=head2 get_p2p_settings

Returns general settings about peer to peer system. If called from RPC, might get values from app_config cache.
If called from bom-events for updated p2p_settings, get updated values from app_config.

=over

=item * C<country> - client residence (2 letters country code)

=back

Returns p2p_settings to either RPC call or to bom-events

=cut

sub get_p2p_settings {
    my %param      = @_;
    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $p2p_advert_config    = BOM::Config::P2P::advert_config()->{$param{country}};
    my $p2p_config           = $app_config->payments->p2p;
    my $local_currency       = BOM::Config::CurrencyConfig::local_currency_for_country(country => $param{country});
    my $exchange_rate        = p2p_exchange_rate($local_currency);
    my $float_range          = BOM::Config::P2P::currency_float_range($local_currency);
    my %all_local_currencies = %BOM::Config::CurrencyConfig::ALL_CURRENCIES;
    my %p2p_countries        = BOM::Config::P2P::available_countries()->%*;
    my @p2p_currencies       = split ',', (BOM::Config::Redis->redis_p2p->get('P2P::LOCAL_CURRENCIES') // '');

    my @local_currencies;
    for my $symbol (sort keys %all_local_currencies) {
        next unless any { exists($p2p_countries{$_}) } $all_local_currencies{$symbol}->{countries}->@*;
        push @local_currencies, {
            symbol       => $symbol,
            display_name => localize($all_local_currencies{$symbol}->{name}),    # transations added in BOM::Backoffice::Script::ExtraTranslations
            has_adverts  => (any { $symbol eq $_ } @p2p_currencies) ? 1 : 0,
            $symbol eq $local_currency ? (is_default => 1) : (),
        };
    }

    my $result = +{
        $p2p_config->archive_ads_days ? (adverts_archive_period => $p2p_config->archive_ads_days) : (),
        order_payment_period        => floor($p2p_config->order_timeout / 60),
        order_expiry_options        => [sort { $a <=> $b } $p2p_config->order_expiry_options->@*],
        cancellation_block_duration => $p2p_config->cancellation_barring->bar_time,
        cancellation_grace_period   => $p2p_config->cancellation_grace_period,
        cancellation_limit          => $p2p_config->cancellation_barring->count,
        cancellation_count_period   => $p2p_config->cancellation_barring->period,
        maximum_advert_amount       => $p2p_config->limits->maximum_advert,
        maximum_order_amount        => $p2p_config->limits->maximum_order,
        adverts_active_limit        => $p2p_config->limits->maximum_ads_per_type,
        order_daily_limit           => $p2p_config->limits->count_per_day_per_client,
        supported_currencies        => [sort(uniq($p2p_config->available_for_currencies->@*))],
        disabled                    => (
            not $p2p_config->enabled
                or $app_config->system->suspend->p2p
        ) ? 1 : 0,
        payment_methods_enabled => $p2p_config->payment_methods_enabled,
        review_period           => $p2p_config->review_period,
        fixed_rate_adverts      => $p2p_advert_config->{fixed_ads},
        float_rate_adverts      => $p2p_advert_config->{float_ads},
        float_rate_offset_limit => Math::BigFloat->new($float_range)->bdiv(2)->bfround(-2, 'trunc')->bstr,
        $p2p_advert_config->{deactivate_fixed}       ? (fixed_rate_adverts_end_date => $p2p_advert_config->{deactivate_fixed}) : (),
        ($exchange_rate->{source} // '') eq 'manual' ? (override_exchange_rate      => $exchange_rate->{quote})                : (),
        feature_level            => $p2p_config->feature_level,
        local_currencies         => \@local_currencies,
        cross_border_ads_enabled => (any { lc($_) eq $param{country} } $p2p_config->cross_border_ads_restricted_countries->@*) ? 0 : 1,
        block_trade              => {
            disabled              => $p2p_config->block_trade->enabled ? 0 : 1,
            maximum_advert_amount => $p2p_config->block_trade->maximum_advert,
        },
        counterparty_term_steps => {
            completion_rate => $p2p_config->advert_counterparty_terms->completion_rate_steps,
            join_days       => $p2p_config->advert_counterparty_terms->join_days_steps,
            rating          => $p2p_config->advert_counterparty_terms->rating_steps,
        },
    };

    return $result;
}

=head2 p2p_exchange_rate

Gets P2P rate from the most of recent of feed or backoffice manual quote for the provided country.
Returns a hashref of quote details or empty hashref if no quote.

=cut

sub p2p_exchange_rate {
    my $currency        = shift;
    my $currency_config = decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->p2p->currency_config);
    my $feed_quote      = ExchangeRates::CurrencyConverter::usd_rate($currency);
    my @quotes;
    push @quotes,
        {
        epoch  => $currency_config->{$currency}{manual_quote_epoch},
        quote  => $currency_config->{$currency}{manual_quote},
        source => 'manual'
        }
        if $currency_config->{$currency} and $currency_config->{$currency}{manual_quote};
    push @quotes,
        {
        epoch  => $feed_quote->{epoch},
        quote  => 1 / $feed_quote->{quote},
        source => 'feed'
        } if $feed_quote;

    @quotes = sort { $b->{epoch} <=> $a->{epoch} } @quotes;

    $quotes[0]->{quote} = p2p_rate_rounding($quotes[0]->{quote}) if @quotes;

    return $quotes[0] // {};
}

=head2 p2p_rate_rounding

Formats an exchange rate to correct number of decimal places.

If $args{display} is true, no more than 2 trailing zeros will be included.

=cut

sub p2p_rate_rounding {
    my ($rate, %args) = @_;
    return undef unless defined $rate;

    $rate = sprintf('%.' . P2P_RATE_PRECISION . 'f', $rate);

    # cut off tailing zeros 3-6
    $rate =~ s/(?<=\.\d{2})(\d*?)0*$/$1/ if $args{display};

    return $rate;
}

=head2 generate_email_unsubscribe_checksum

It creates the checksum for unsubscibe request.
Returns a hmac_sha1_hex hash or empty string for the given loginid and email.

=cut

sub generate_email_unsubscribe_checksum {
    my $loginid = shift;
    my $email   = shift;
    return q{} unless $loginid || $email;
    my $user_info = $loginid . $email;
    my $hash_key  = BOM::Config::third_party()->{customerio}->{hash_key};
    return hmac_sha1_hex($user_info, $hash_key) // q{};
}

=head2 notify_submission_of_documents_for_pending_payout

send notification to client of document submission pending

=over

=item * C<client> - properties to update the status of the client 

=back

=cut

sub notify_submission_of_documents_for_pending_payout {
    my ($client) = @_;
    my $brand = Brands->new(name => 'deriv');

    my $req = BOM::Platform::Context::Request->new(
        brand_name => $brand->name,
        app_id     => $client->source,
    );
    BOM::Platform::Context::request($req);

    my $due_date = Date::Utility->today->plus_time_interval('3d');

    BOM::Platform::Event::Emitter::emit(
        account_verification_for_pending_payout => {
            loginid    => $client->loginid,
            properties => {
                email => $client->email,
                date  => $due_date->date_ddmmyyyy,
            }});
}

=head2 is_currency_pair_transfer_blocked

will check if the currency pair is blocked or not

=over

=item * C<from_currency> - currency code which is being transferred from

=item * C<to_currency> - currency code which is being transferred to

=back

=cut

sub is_currency_pair_transfer_blocked {
    my @param                       = @_;
    my $app_config                  = BOM::Config::Runtime->instance->app_config;
    my $transfer_currency_pair_json = $app_config->system->suspend->transfer_currency_pair;
    return 0 unless defined $transfer_currency_pair_json;

    my $transfer_currency_pair = decode_json($transfer_currency_pair_json);
    return 0 unless defined $transfer_currency_pair->{'currency_pairs'};
    return first {
        my $pair = $_;
        ($pair->[0] eq $param[0] and $pair->[1] eq $param[1])
            or ($pair->[1] eq $param[0] and $pair->[0] eq $param[1])
    } @{$transfer_currency_pair->{'currency_pairs'}};

}

=head2 trim_immutable_client_fields

It is responsible for trimming client fields defined in the constant 
PROFILE_FIELDS_IMMUTABLE_DUPLICATED to avoid whitespace entry

=over 4

=item - $inputs:  Inputs containing client related fields

=back

Returns inputs after trimming the fields matching with immutable_fields

=cut

sub trim_immutable_client_fields {
    my %inputs           = (shift)->%*;
    my @immutable_fields = BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_DUPLICATED()->@*;
    my %immutable_fields = map { $_ => 1 } @immutable_fields;

    for my $field (keys %inputs) {
        if ($immutable_fields{$field}) {
            $inputs{$field} = trim($inputs{$field}) if defined $inputs{$field};
        }
    }
    return \%inputs;
}

=head2 get_valid_state

It attempts to return the 'value' for state if it can be obtained from validate_state, otherwise, returns empty string
For state values 'ba', 'BA', 'bali', 'Bali' and residence 'id' - returns 'BA'
For state values '--others--', 'please select' and residence 'id' - returns ''

=over 4

=item * C<$state>     -  The address_state which needs to be checked
=item * C<$residence> -  The residence against which the state needs to be checked

=back

Returns the correct state value, otherwise empty string

=cut

sub get_valid_state {
    my ($state, $residence) = @_;

    return '' unless $state and $residence;

    my $match = BOM::Platform::Locale::validate_state($state, $residence);

    return uc($match->{value} // '');
}

=head2 po_box_patterns

A helper function that loads the C<po_box_address_patterns.yml> file carrying the PO Box regex patterns.

=cut

sub po_box_patterns {
    my $path = Path::Tiny::path(__DIR__)->parent(3)->child('share', 'po_box_address_patterns.yml');
    state $po_box_address_patterns = YAML::XS::LoadFile($path);
    return $po_box_address_patterns;
}

=head2 has_po_box_address

Check if the client's address contains a string we identify as PO BOX

It takes:

=over 4

=item * C<client> - BOM::User::Client instance

=back

Returns a C<boolean>.

=cut

sub has_po_box_address {
    my ($client) = @_;

    my $client_address = [$client->address_1, $client->address_2];

    my $po_box_address_patterns = [map { qr/\b$_\b/i } @{po_box_patterns()}];

    foreach my $address_line (@$client_address) {
        foreach my $pattern (@$po_box_address_patterns) {
            return 1 if $address_line =~ $pattern;
        }
    }

    return 0;
}

1;
