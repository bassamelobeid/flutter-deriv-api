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
use WebService::SendBird;
use JSON::MaybeUTF8 qw(:v1);
use Digest::SHA     qw(hmac_sha1_hex);
use List::Util      qw(any uniq);

use BOM::Platform::Context qw(request);
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;
use BOM::Config::P2P;

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

# set exclude_until to n-months from now and returns that in yyyy-mm-dd format
sub set_exclude_until_for {
    my ($client, $num_months) = @_;
    my $to_date = Date::Utility->new(DateTime->now()->add(months => $num_months))->date_yyyymmdd;
    $client->set_exclusion->exclude_until($to_date);
    $client->save();
    return $to_date;
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
            qw(payment_method payment_method_names is_active local_currency rate min_order_amount_limit max_order_amount_limit rate_offset effective_rate)
        ],
        client            => [qw(is_visible payment_info contact_info active_orders amount remaining_amount min_order_amount max_order_amount)],
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
                $val                            = join(',', sort @$val) if ref $val eq 'ARRAY';
                $state->{$id}{$field}           = $val                  if any { $_ eq $field } ($fields{common}->@*, $fields{advertiser_common}->@*);
                $state->{$id}{$field}{$loginid} = $val                  if any { $_ eq $field } ($fields{client}->@*, $fields{advertiser_client}->@*);
            }
        }
    }

    $p2p_redis->set($key, encode_json_utf8($state), 'EX', P2P_ADVERT_STATE_EXPIRY);
    return $updates;
}

=head2 p2p_exchange_rate

Gets P2P rate from the most of recent of feed or backoffice manual quote for the provided country.
Returns a hashref of quote details or empty hashref if no quote.

=cut

sub p2p_exchange_rate {
    my $currency = shift;

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

=head2 status_op_processor

Given an input and a client, this sub will process the given statuses expecting multiple
statuses passed.

It takes the following arguments:

=over 4

=item * C<client> - the client instance

=item * C<input> - a hashref of the user inputs

=back

The input should have a B<status_op> key that may contain:

=over 4

=item * C<remove> - this op performs a status removal from the client

=item * C<remove_siblings> - the same as `remove` but will also remove the status from siblings

=item * C<sync> - this op copies the given statuses to the siblings

=back

From the input hashref we will look for a `status_checked` value that can either be an arrayref or string (must check for that).
This value represents the given status codes.

Returns a summary to print out or undef if nothing happened.

=cut

sub status_op_processor {
    my ($client, $args) = @_;
    my $status_op      = $args->{status_op};
    my $status_checked = $args->{status_checked} // [];
    $status_checked = [$status_checked] unless ref($status_checked);
    my $client_status_type = $args->{untrusted_action_type};
    my $reason             = $args->{reason};
    my $clerk              = $args->{clerk} // BOM::Backoffice::Auth0::get_staffname();
    my $status_map         = {
        disabledlogins            => 'disabled',
        lockcashierlogins         => 'cashier_locked',
        unwelcomelogins           => 'unwelcome',
        nowithdrawalortrading     => 'no_withdrawal_or_trading',
        lockwithdrawal            => 'withdrawal_locked',
        lockmt5withdrawal         => 'mt5_withdrawal_locked',
        duplicateaccount          => 'duplicate_account',
        allowdocumentupload       => 'allow_document_upload',
        internalclient            => 'internal_client',
        notrading                 => 'no_trading',
        sharedpaymentmethod       => 'shared_payment_method',
        cryptoautorejectdisabled  => 'crypto_auto_reject_disabled',
        cryptoautoapprovedisabled => 'crypto_auto_approve_disabled',
    };

    if ($client_status_type && $status_map->{$client_status_type}) {
        push(@$status_checked, $client_status_type);
    }
    @$status_checked = uniq @$status_checked;
    return undef unless $status_op;
    return undef unless scalar $status_checked->@*;

    my $loginid = $client->loginid;
    my $summary = '';
    my $old_db  = $client->get_db();
    # assign write access to db_operation to perform client_status delete/copy operation
    $client->set_db('write') if 'write' ne $old_db;

    for my $status ($status_checked->@*) {
        try {
            if ($status_op eq 'remove') {
                my $client_status_clearer_method_name = 'clear_' . $status;
                $client->status->$client_status_clearer_method_name;
                $summary .= "<div class='notify'><b>SUCCESS :</b>&nbsp;&nbsp;<b>$status</b>&nbsp;&nbsp;has been removed from <b>$loginid</b></div>";
            } elsif ($status_op eq 'remove_siblings' or $status_op eq 'remove_accounts') {
                $summary .= status_op_processor(
                    $client,
                    {
                        status_checked => [$status],
                        status_op      => 'remove',
                    });

                my $updated_client_loginids = $client->clear_status_and_sync_to_siblings($status, $clerk, $status_op eq 'remove_accounts');
                my $siblings = join ', ', $updated_client_loginids->@*;

                if (scalar $updated_client_loginids->@*) {
                    $summary .=
                        "<div class='notify'><b>SUCCESS :</b><&nbsp;&nbsp;<b>$status</b>&nbsp;&nbsp;has been removed from siblings:<b>$siblings</b></div>";
                }
            } elsif ($status_op eq 'sync' or $status_op eq 'sync_accounts') {
                $status = $status_map->{$status}       ? $status_map->{$status}           : $status;
                $reason = $reason =~ /SELECT A REASON/ ? $client->status->reason($status) : $reason;
                my $updated_client_loginids = $client->copy_status_to_siblings($status, $clerk, $status_op eq 'sync_accounts', $reason);
                my $siblings = join ', ', $updated_client_loginids->@*;

                if (scalar $updated_client_loginids->@*) {
                    $summary .=
                        "<div class='notify'><b>SUCCESS :</b>&nbsp;&nbsp;<b>$status</b>&nbsp;&nbsp;has been copied to siblings:<b>$siblings</b></div>";
                }
            }
        } catch {
            my $fail_op = 'process';
            $fail_op = 'remove'                                                                        if $status_op eq 'remove';
            $fail_op = 'remove from siblings'                                                          if $status_op eq 'remove_siblings';
            $fail_op = 'copy to siblings'                                                              if $status_op eq 'sync';
            $fail_op = 'copy to accounts, only DISABLED ACCOUNTS can be synced to all accounts'        if $status_op eq 'sync_accounts';
            $fail_op = 'remove from accounts, only DISABLED ACCOUNTS can be removed from all accounts' if $status_op eq 'remove_accounts';

            $summary .=
                "<div class='notify notify--danger'><b>ERROR :</b>&nbsp;&nbsp;Failed to $fail_op, status <b>$status</b>. Please try again.</div>";
        }
    }
    # once db operation is done, set back db_operation to replica
    $client->set_db($old_db) if 'write' ne $old_db;

    return $summary;
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

1;
