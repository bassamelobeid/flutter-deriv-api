package BOM::Event::Services::Track;
use strict;

use warnings;
use feature 'state';
use utf8;

use Log::Any qw($log);
use Syntax::Keyword::Try;
use Locale::Country qw(code2country);
use Time::Moment;
use Date::Utility;
use Brands;
use List::Util            qw(first any uniq);
use Storable              qw(dclone);
use Format::Util::Numbers qw(formatnumber);
use Future::AsyncAwait;

use BOM::User;
use BOM::User::Client;
use BOM::Event::Services;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Locale  qw(get_state_by_id);
use BOM::Database::Model::UserConnect;

# Constant user_id for anonymous events.
use constant BINARY_CUSTOMER => 1;

=head1 NAME

BOM::Event::Services::Track

=head1 DESCRIPTION

Provides functions for tracking events.

=cut

# loginid, lang and brand are always sent for events, and do not need to be inlcuded here.

my %EVENT_PROPERTIES = (
    reset_password_request      => [qw(loginid first_name verification_url social_login email lost_password language code)],
    reset_password_confirmation => [qw(loginid first_name email type)],
    identify                    => [
        qw (address age available_landing_companies avatar birthday company created_at description email first_name gender id landing_companies last_name name phone provider title username website currencies country unsubscribed)
    ],
    login  => [qw (browser device ip new_signin_activity location app_name)],
    signup => [qw (type subtype currency landing_company date_joined first_name last_name phone address age country provider email_consent)],
    transfer_between_accounts => [
        qw(revenue currency value from_account to_account from_currency to_currency from_amount to_amount source fees is_from_account_pa
            is_to_account_pa gateway_code remark time id)
    ],
    account_closure     => [qw(new_campaign name brand closing_reason loginids_disabled loginids_failed email_consent)],
    account_reactivated => [qw(first_name needs_poi profile_url resp_trading_url live_chat_url new_campaign)],
    app_registered      => [qw(name scopes redirect_uri verification_uri app_markup_percentage homepage github appstore googleplay app_id)],
    app_updated         => [qw(name scopes redirect_uri verification_uri app_markup_percentage homepage github appstore googleplay app_id)],
    app_deleted         => [qw(app_id)],
    api_token_created   => [qw(name scopes)],
    api_token_deleted   => [qw(name scopes)],
    profile_change      => [qw(brand updated_fields live_chat_url origin)],
    mt5_signup          => [
        qw(account_type language mt5_group mt5_loginid sub_account_type client_first_name type_label mt5_integer_id brand mt5_server mt5_server_location mt5_server_region mt5_server_environment mt5_dashboard_url live_chat_url)
    ],
    mt5_password_changed        => [qw(mt5_loginid)],
    mt5_inactive_notification   => [qw(email name closure_date accounts)],
    mt5_inactive_account_closed => [qw(name title mt5_accounts live_chat_url)],
    document_upload             => [qw(document_type expiration_date file_name id upload_date uploaded_manually_by_staff)],
    set_financial_assessment    => [
        qw(education_level employment_industry estimated_worth income_source net_income occupation account_turnover binary_options_trading_experience
            binary_options_trading_frequency cfd_trading_experience cfd_trading_frequency employment_status forex_trading_experience forex_trading_frequency other_instruments_trading_experience
            other_instruments_trading_frequency source_of_wealth)
    ],
    self_exclude            => [qw(unsubscribed)],
    p2p_advertiser_approved => [],
    p2p_order_created       => [
        qw(user_role order_type  order_id amount currency local_currency buyer_user_id buyer_nickname seller_user_id seller_nickname order_created_at exchange_rate)
    ],
    p2p_order_buyer_has_paid => [
        qw(user_role order_type order_id amount currency local_currency buyer_user_id buyer_nickname seller_user_id seller_nickname order_created_at exchange_rate)
    ],
    p2p_order_seller_has_released => [
        qw(user_role order_type order_id amount currency local_currency buyer_user_id buyer_nickname seller_user_id seller_nickname order_created_at exchange_rate)
    ],
    p2p_order_cancelled => [
        qw(user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at exchange_rate)
    ],
    p2p_order_expired => [
        qw(buyer_has_confirmed user_role order_type  order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at exchange_rate)
    ],
    p2p_order_dispute        => [qw(user_role title order_id disputer dispute_reason)],
    p2p_order_timeout_refund => [
        qw(user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at exchange_rate)
    ],
    p2p_order_dispute_complete => [
        qw(dispute_reason disputer user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at)
    ],
    p2p_order_dispute_refund => [
        qw(dispute_reason disputer user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at)
    ],
    p2p_order_dispute_fraud_complete => [
        qw(dispute_reason disputer user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at)
    ],
    p2p_order_dispute_fraud_refund => [
        qw(dispute_reason disputer user_role order_type order_id amount currency local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname order_created_at)
    ],
    p2p_archived_ad                     => [qw(adverts)],
    multiplier_hit_type                 => [qw(contract_id hit_type profit sell_price currency)],
    multiplier_near_expire_notification => [qw(loginid contract_id)],
    multiplier_near_dc_notification     => [qw(loginid contract_id)],
    payment_deposit             => [qw(payment_processor transaction_id is_first_deposit trace_id amount payment_fee currency payment_method remark)],
    payment_withdrawal          => [qw(transaction_id trace_id amount payment_fee currency payment_method)],
    payment_withdrawal_reversal => [qw(transaction_id trace_id amount payment_fee currency payment_method)],
    trading_platform_account_created                 => [qw(first_name login account_id account_type market_type platform)],
    trading_platform_password_reset_request          => [qw(first_name verification_url code platform)],
    trading_platform_password_changed                => [qw(first_name contact_url type logins platform)],
    trading_platform_password_change_failed          => [qw(first_name contact_url type successful_logins failed_logins platform)],
    trading_platform_investor_password_reset_request => [qw(first_name verification_url code)],
    trading_platform_investor_password_changed       => [qw(first_name contact_url type login)],
    trading_platform_investor_password_change_failed => [qw(first_name contact_url type login)],
    identity_verification_rejected                   => [qw(authentication_url live_chat_url title)],
    risk_disclaimer_resubmission                     => [qw(website_name title salutation)],
    crypto_withdrawal_email                          => [qw(loginid transaction_hash transaction_url amount currency live_chat_url title)],
    crypto_withdrawal_rejected_email                 => [
        qw(loginid reject_reason amount currency_code title live_chat_url meta_data fiat_account cashier_transfer_url cashier_p2p_url cashier_withdrawal_url)
    ],
    p2p_advert_created =>
        [qw(advert_id created_time type account_currency local_currency country amount rate rate_type min_order_amount max_order_amount is_visible)],
    p2p_advertiser_cancel_at_fault    => [qw(order_id cancels_remaining)],
    p2p_advertiser_temp_banned        => [qw(order_id limit block_end_date block_end_time)],
    request_change_email              => [qw(loginid first_name email code verification_uri live_chat_url social_signup time_to_expire_in_min)],
    verify_change_email               => [qw(loginid first_name email code verification_uri live_chat_url social_signup time_to_expire_in_min)],
    confirm_change_email              => [qw(loginid first_name email live_chat_url social_signup)],
    unknown_login                     => [qw(first_name email title country device browser app_name ip is_reset_password_allowed password_reset_url)],
    account_with_false_info_locked    => [qw(email authentication_url profile_url is_name_change)],
    underage_account_closed           => [qw(tnc_approval)],
    account_opening_new               => [qw(first_name verification_url code email live_chat_url)],
    account_opening_existing          => [qw(loginid email live_chat_url login_url password_reset_url)],
    self_tagging_affiliates           => [qw(email live_chat_url)],
    request_payment_withdraw          => [qw(loginid email live_chat_url verification_url code paymentagent)],
    verify_email_closed_account_other => [qw(loginid email type live_chat_url)],
    verify_email_closed_account_reset_password  => [qw(loginid email type live_chat_url)],
    verify_email_closed_account_account_opening => [qw(loginid email type live_chat_url)],
    account_verification_for_pending_payout     => [qw(date email)],
    authenticated_with_scans                    => [qw(first_name email contact_url live_chat_url)],
    pa_transfer_confirm                         => [qw(loginid email pa_loginid pa_first_name pa_last_name pa_name client_name amount currency)],
    age_verified                                => [qw(first_name loginid contact_url live_chat_url poi_url)],
    bonus_approve                               => [qw(full_name website contact_url live_chat_url amount currency tac_url)],
    bonus_reject                                => [qw(full_name website contact_url live_chat_url tac_url poi_url)],
    pa_withdraw_confirm         => [qw(email client_loginid pa_loginid pa_first_name pa_last_name pa_name client_name amount currency)],
    withdrawal_rejected         => [qw(first_name reason remark)],
    request_edd_document_upload => [qw(first_name email login_url expiry_date live_chat_url)],
    p2p_order_confirm_verify    => [qw(verification_url order_id order_amount order_currency buyer_name code live_chat_url password_reset_url)],
);

# Put the common events that should have simillar data struture to delivering it to Segment.

my @COMMON_EVENT_METHODS = qw(
    account_with_false_info_locked
    underage_account_closed
    account_verification_for_pending_payout
    api_token_created
    api_token_deleted
    account_reactivated
    mt5_password_changed
    app_registered
    app_updated
    app_deleted
    p2p_archived_ad
    p2p_advert_created
    p2p_advertiser_cancel_at_fault
    p2p_advertiser_temp_banned
    crypto_withdrawal_email
    crypto_withdrawal_rejected_email
    payment_deposit
    payment_withdrawal
    payment_withdrawal_reversal
    p2p_advertiser_approved
    reset_password_request
    confirm_change_email
    verify_change_email
    request_change_email
    reset_password_confirmation
    authenticated_with_scans
    age_verified
    bonus_approve
    bonus_reject
    request_edd_document_upload
    pa_transfer_confirm
    pa_withdraw_confirm
    withdrawal_rejected
    p2p_order_confirm_verify
);

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

=head2 _api

Provides a wrapper instance for communicating with the Segment web API.
It's a singleton - we don't want to leak memory by creating new ones for every event.

=cut

sub _api {
    return $services->rudderstack();
}

=head2 multiplier_hit_type

It is triggered for each B<multiplier_hit_type> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. multiplier_hit_type Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub multiplier_hit_type {
    my ($args) = @_;

    return track_event(
        event      => 'multiplier_hit_type',
        loginid    => $args->{loginid},
        properties => $args,
    );
}

=head2 multiplier_near_expire_notification

It is triggered for each B<multiplier_near_expire_notification> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. login id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub multiplier_near_expire_notification {
    my ($args) = @_;

    return track_event(
        event      => 'multiplier_near_expire_notification',
        loginid    => $args->{loginid},
        properties => $args,
    );
}

=head2 multiplier_near_dc_notification

It is triggered for each B<multiplier_near_dc_notification> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. login id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub multiplier_near_dc_notification {
    my ($args) = @_;

    return track_event(
        event      => 'multiplier_near_dc_notification',
        loginid    => $args->{loginid},
        properties => $args,
    );
}

=head2 login

It is triggered for each B<login> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub login {
    my ($args) = @_;
    my $properties = $args->{properties};

    my $app = request->app // {};
    $properties->{app_name} = $app->{name} // '';

    return track_event(
        event                => 'login',
        loginid              => $args->{loginid},
        properties           => $properties,
        is_identify_required => 1,
    );
}

=head2 signup

It is triggered for each B<signup> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<client> - required. Client instance.

=item * C<properties> - event proprerties.

=back

=cut

sub signup {
    my ($args) = @_;

    my $client = BOM::User::Client->new({loginid => $args->{loginid}})
        or die 'Could not instantiate client for login ID ' . $args->{loginid};
    my $properties = $args->{properties};

    # traits will be used for identify
    my $traits = _create_traits($client);
    $traits->{signup_brand} = request->brand_name;

    if ($properties->{utm_tags}) {
        $traits->{$_} = $properties->{utm_tags}{$_} for keys $properties->{utm_tags}->%*;
        delete $properties->{utm_tags};
    }

    # properties will be sent for the event itself
    $properties->{$_} = $traits->{$_} for grep { $traits->{$_} } qw(first_name last_name phone address age country);

    $properties->{currency}        = $client->account->currency_code if $client->account;
    $properties->{landing_company} = $client->landing_company->short;
    $properties->{date_joined}     = $client->date_joined;
    $properties->{email_consent}   = $client->user->email_consent;
    $properties->{first_name}      = $properties->{first_name} // $client->first_name // '';

    my $user_connect = BOM::Database::Model::UserConnect->new;
    $properties->{provider} = $client->user ? $user_connect->get_connects_by_user_id($client->user->{id})->[0] // 'email' : 'email';

    return track_event(
        event                => 'signup',
        properties           => $properties,
        client               => $client,
        traits               => $traits,
        is_identify_required => 1
    );

}

=head2 account_closure

It is triggered for each B<account_closure> event emitted, delivering the data to Segment.

=cut

sub account_closure {
    my ($args) = @_;

    return track_event(
        event                => 'account_closure',
        loginid              => $args->{loginid},
        properties           => $args,
        is_identify_required => 1,
    );
}

=head2 new_mt5_signup

It is triggered for each B<new mt5 signup> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<client> - required. Client instance

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub new_mt5_signup {
    my ($args) = @_;

    return track_event(
        event      => 'mt5_signup',
        client     => $args->{client},
        properties => $args,
    );
}

=head2 profile_change 

It is triggered for each B<changing in user profile> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<client> - required. Client instance.

=item * C<properties> - Free-form dictionary of event properties containing key updated_fields.

=back

=cut

sub profile_change {
    my ($args)     = @_;
    my $client     = BOM::User::Client->new({loginid => $args->{loginid}});
    my $properties = $args->{properties} // {};

    my $traits = _create_traits($client);

    # Modify some properties to be more readable in segment
    $properties->{updated_fields}{address_state} = $traits->{address}{state} if $properties->{updated_fields}{address_state};
    foreach my $field (qw /citizen residence place_of_birth/) {
        $properties->{updated_fields}{$field} = Locale::Country::code2country($properties->{updated_fields}{$field})
            if (defined $properties->{updated_fields}{$field} and $properties->{updated_fields}{$field} ne '');
    }

    return track_event(
        event      => 'profile_change',
        properties => {
            updated_fields => $properties->{updated_fields},
            origin         => $properties->{origin},
            live_chat_url  => $properties->{live_chat_url},
        },
        client               => $client,
        traits               => $traits,
        is_identify_required => 1,
    );
}

=head2 transfer_between_accounts

It is triggered for each B<transfer_between_accounts> event emitted, delivering it to Segment.

It is called with the following parameters: 

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties

=back

=cut

sub transfer_between_accounts {
    my ($args) = @_;

    # Deref and ref, So we don't modify the main properties that is passed as an argument
    my $properties = {($args->{properties} // {})->%*};

    $properties->{revenue}  = -($properties->{from_amount} // die('required from_account'));
    $properties->{currency} = $properties->{from_currency} // die('required from_currency');
    $properties->{value}    = $properties->{from_amount}   // die('required from_amount');
    $properties->{time}     = _time_to_iso_8601($properties->{time} // die('required time'));

    $properties->{fees} = formatnumber('amount', $properties->{from_currency}, $properties->{fees} // 0);

    # Do not send PaymentAgent fields to Segment when it's not a payment agent transfer
    if ($properties->{gateway_code} ne 'payment_agent_transfer') {
        delete $properties->{is_to_account_pa};
        delete $properties->{is_from_account_pa};
    }

    return track_event(
        event      => 'transfer_between_accounts',
        loginid    => $args->{loginid},
        properties => $properties
    );
}

=head2 document_upload

It is triggered for each B<document_upload>, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<client> - required. Client instance.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub document_upload {
    my ($args) = @_;
    my $properties = {$args->{properties}->%*};

    $properties->{upload_date} = _time_to_iso_8601($properties->{upload_date} // die('required time'));
    $properties->{uploaded_manually_by_staff} //= 0;

    return track_event(
        event      => 'document_upload',
        client     => $args->{client},
        properties => $properties
    );
}

=head2 self_exclude

It is triggered for each B<self_exclude> event emitted, delivering it to Segment.

=cut

sub self_exclude {
    my ($args) = @_;

    return track_event(
        event                => 'self_exclude',
        loginid              => $args->{loginid},
        properties           => $args,
        is_identify_required => 1
    );
}

=head2 set_financial_assessment

It is triggered for each B<set_financial_assessment> event emitted, delivering it to Segment.

=cut

sub set_financial_assessment {
    my ($args) = @_;

    return track_event(
        event      => 'set_financial_assessment',
        loginid    => $args->{loginid},
        properties => $args->{params},
    );
}

=head2 mt5_inactive_notification

It is triggered for each B<mt5_inactive_notification> event emitted, delivering it to Segment. It's called with following arguments:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<email> - required. Email address to which the notification should be sent.

=item * C<closure_date> - required. The closure date of the accounts, represented as Linux epoch.

=item * C<accounts> - required. An array-ref holding a list of MT5 accounts with following structure:

=over

=item - C<loginid> - MT5 account id.

=item - C<account_type> - MT5 account type.

=back

=back

=cut

sub mt5_inactive_notification {
    my ($args) = @_;

    my $loginid = delete $args->{loginid};
    return track_event(
        event      => 'mt5_inactive_notification',
        loginid    => $loginid,
        properties => $args,
    );
}

=head2 mt5_inactive_account_closed

Triggered for each B<mt5_inactive_account_closed> event emitted, delivering it to Segment.

=cut

sub mt5_inactive_account_closed {
    my ($args) = @_;

    my $loginid = delete $args->{loginid};
    return track_event(
        event      => 'mt5_inactive_account_closed',
        loginid    => $loginid,
        properties => $args,
    );
}

sub p2p_order_created {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    return _p2p_order_track($order, $parties, 'p2p_order_created');
}

sub p2p_order_buyer_has_paid {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    return _p2p_order_track($order, $parties, 'p2p_order_buyer_has_paid');
}

sub p2p_order_seller_has_released {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    return _p2p_order_track($order, $parties, 'p2p_order_seller_has_released');
}

sub p2p_order_cancelled {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    return _p2p_order_track($order, $parties, 'p2p_order_cancelled');
}

sub p2p_order_expired {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};

    my $buyer_has_confirmed = ($order->{status} eq 'refunded') ? 0 : 1;

    return _p2p_order_track(
        $order, $parties,
        'p2p_order_expired',
        {
            buyer_has_confirmed => $buyer_has_confirmed // 0,
        });
}

=head2 p2p_order_dispute

Sends to segment the disputed order for further email sending or other events. 
Two events should be fired off, one for each party.

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};

    my %properties = (
        disputer       => 'buyer',
        order_id       => $order->{id},
        dispute_reason => $order->{dispute_details}{dispute_reason},
    );

    # most emails use the same titles
    my $buyer_title  = localize('We’re investigating your dispute');
    my $seller_title = localize('We’re investigating and need more info');

    # seller raised a dispute
    if ($order->{dispute_details}{disputer_loginid} eq $parties->{seller}->loginid) {
        $properties{disputer} = 'seller';
        ($seller_title, $buyer_title) = ($buyer_title, $seller_title);
        if ($properties{dispute_reason} eq 'buyer_overpaid') {
            $buyer_title  = localize('You’ve paid more than the order amount');
            $seller_title = localize('Please return the excess funds');
        }

    } elsif ($properties{dispute_reason} eq 'buyer_underpaid') {    # buyer raised a dispute
        $buyer_title  = localize('Please make the full payment');
        $seller_title = localize('The buyer hasn’t made the full payment');
    }

    return Future->needs_all(
        track_event(
            event      => 'p2p_order_dispute',
            client     => $parties->{buyer},
            properties => {
                user_role => 'buyer',
                title     => $buyer_title,
                %properties,
            },
        ),
        track_event(
            event      => 'p2p_order_dispute',
            client     => $parties->{seller},
            properties => {
                user_role => 'seller',
                title     => $seller_title,
                %properties,
            },
        ),
    );
}

=head2 p2p_order_dispute_complete

Sent when a dispute was completed without fraud.

It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute_complete {
    return _p2p_dispute_resolution(@_, event => 'p2p_order_dispute_complete');
}

=head2 p2p_order_dispute_refund

Sent when a dispute was refunded without fraud.

It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute_refund {
    return _p2p_dispute_resolution(@_, event => 'p2p_order_dispute_refund');
}

=head2 p2p_order_fraud_refund

Sent when a dispute was refunded, fraud involved.

It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute_fraud_refund {
    return _p2p_dispute_resolution(@_, event => 'p2p_order_dispute_fraud_refund');
}

=head2 p2p_order_dispute_fraud_complete

Sent when a dispute was completed, fraud involved.

It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute_fraud_complete {
    return _p2p_dispute_resolution(@_, event => 'p2p_order_dispute_fraud_complete');
}

=head2 p2p_order_timeout_refund

Sends to segment the order refunded tracking event for both parties involved. 
It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_timeout_refund {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    return _p2p_order_track($order, $parties, 'p2p_order_timeout_refund');
}

=head2 _p2p_dispute_resolution

Since the p2p_order_dispute family of subs are identical, we will refactor them
into this handy sub.

It takes the same arguments as those subs, plus the event name:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=item * C<event> The event name

=back

Returns, a Future needing both tracking events.

=cut

sub _p2p_dispute_resolution {
    my %args = @_;
    my ($order, $parties, $event) = @args{qw(order parties event)};
    my $disputer = 'buyer';
    $disputer = 'seller' if $parties->{seller}->loginid eq $order->{dispute_details}->{disputer_loginid};

    return _p2p_order_track(
        $order, $parties, $event,
        {
            dispute_reason => $order->{dispute_details}->{dispute_reason},
            disputer       => $disputer
        });
}

=head2 _p2p_order_track

Since the p2p family of subs are identical, we will refactor them
into this handy sub.

It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=item * C<event> The event name

=item * C<extras> (optional) A hashref containing extra properties to pass on

=back

Returns, a Future needing both tracking events.

=cut

sub _p2p_order_track {
    my ($order, $parties, $event, $extras) = @_;
    $extras //= {};

    return Future->needs_all(
        track_event(
            event      => $event,
            client     => $parties->{buyer},
            properties => {_p2p_properties($order, $parties, 'buyer')->%*, $extras->%*},
        ),
        track_event(
            event      => $event,
            client     => $parties->{seller},
            properties => {_p2p_properties($order, $parties, 'seller')->%*, $extras->%*},
        ),
    );
}

=head2 _p2p_properties

Since p2p events have a lot of common properties it makes sense to centralize 
the common fields in a handy sub.
It takes the following arguments:

=over 4

=item * C<order> the p2p order being emitted

=item * C<parties> a hashref containing info for both buyer and seller

=item * C<side> which side this event is for (seller/buyer)

=back

Returns, a hashref with common p2p properties for event tracking.

=cut

sub _p2p_properties {
    my ($order, $parties, $side) = @_;

    return {
        user_role        => $side,
        order_type       => $order->{type},
        order_id         => $order->{id},
        exchange_rate    => $order->{rate_display},
        amount           => $order->{amount_display},
        currency         => $order->{account_currency},
        local_currency   => $order->{local_currency},
        buyer_user_id    => $parties->{buyer}->{binary_user_id},
        buyer_nickname   => $parties->{buyer_nickname} // '',
        seller_user_id   => $parties->{seller}->{binary_user_id},
        seller_nickname  => $parties->{seller_nickname} // '',
        order_created_at => Time::Moment->from_epoch($order->{created_time})->to_string,
    };
}

=head2 track_event

A public method that performs event validation and tracking by Segment B<track> and (if requested) B<identify> API calls.
All tracking events should be sent via this method to ensure they are validated correctly.
C<loginid>, C<lang> and C<brand> will be automatically added to all track properties.

Takes the following named parameters:

=over 4

=item * C<event> - Name of the event to be emitted.

=item * C<loginid> - Loginid of the client, optional if client is provided.

=item * C<client> - Client instance, optional if loginid is provided.

=item * C<properties> - event proprties as a hash ref (optional).

=item * C<is_identify_required> - a binary flag determining wether or not make an B<identify> API call (optional)

=item * C<traits> - Segment traits to be used when C<is_identify_required> is true (optional - defaults to _create_traits())

=item * C<brand> - the brand associated with the event as a L<Brands> object (optional - defaults to request's brand)

=item * C<app_id> - the app id associated with the event (optional - defaults to request's app id)

=back

=cut

async sub track_event {
    my %args = @_;

    my $client = $args{client} // ($args{loginid} ? BOM::User::Client->get_client_instance($args{loginid}) : undef);
    die($args{event} . ' tracking triggered with an invalid or no loginid and no client. Please inform backend team if it continues to occur.')
        unless $client
        or $args{anonymous};

    return unless _validate_event($args{event}, $args{brand});

    my %customer_args = (user_id => $client ? $client->binary_user_id : BINARY_CUSTOMER);
    $customer_args{traits} = $args{traits} // _create_traits($client) if $args{is_identify_required};
    my $customer = _api->new_customer(%customer_args);

    my $context = _create_context($args{brand});

    $log->debugf('Tracked %s for user %s', $args{event}, $customer_args{user_id});

    # Schedule the _send_track_request or identify request to be invoked as soon as the current round of IO operations is complete.
    await $loop->later;

    return await Future->needs_all(
        _send_track_request(
            $customer,
            {
                ($client ? (loginid => $client->loginid) : ()),
                lang  => uc(($client ? $client->user->preferred_language : undef) // request->language // ''),
                brand => $args{brand}->{name}       // request->brand->name,
                email => $args{properties}->{email} // ($client ? $client->email : undef),
                ($args{properties} // {})->%*,
            },
            $args{event},
            $context,
        ),
        $args{is_identify_required}
        ? $customer->identify(context => $context)
        : Future->done,
    );
}

=head2 _send_track_request

A private method that makes a Segment B<track> API call, just letting valid(known) properties to pass through.
This should only be called by C<track_event> and not called directly.
It is called with the following parameters:

=over

=item * C<customer> - Customer object, traits are not needed.

=item * C<properties> - Free-form dictionary of event properties.

=item * C<event> - The event name that will be sent to the Segment.

=item * C<context> - Request context.

=back

=cut

sub _send_track_request {
    my ($customer, $properties, $event, $context) = @_;

    die "Unknown event <$event> tracking request was triggered" unless $EVENT_PROPERTIES{$event};

    # filter invalid or unknown properties out
    my $valid_event_properties = [$EVENT_PROPERTIES{$event}->@*, 'loginid', 'lang', 'brand'];
    my $valid_properties       = {map { defined $properties->{$_} ? ($_ => $properties->{$_}) : () } @$valid_event_properties};

    return $customer->track(
        event      => $event,
        properties => $valid_properties,
        context    => $context,
    );
}

=head2 _create_context

Dictionary of extra information that provides context about a message.
It takes the following args: 

=over

=item *C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _create_context {
    my $brand = shift // request->brand;
    return {
        locale => request->language,
        app    => {name => $brand->name},
        active => 1
    };
}

=head2 _create_traits

Create customer traits for segement identify call.
Arguments:

=over

=item * C<client> - required. A L<BOM::User::Client> object representing a client.

=item * C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _create_traits {
    my ($client, $brand) = @_;
    $brand //= request->brand;

    my @siblings     = $client->user ? $client->user->clients(include_disabled => 1) : ($client);
    my @mt5_loginids = $client->user ? $client->user->get_mt5_loginids               : ();
    my $user_connect = BOM::Database::Model::UserConnect->new;
    my $provider     = $client->user ? $user_connect->get_connects_by_user_id($client->user->{id})->[0] // 'email' : 'email';

    my $country_config              = $brand->countries_instance->countries_list->{$client->residence};
    my $available_landing_companies = join ',' => uniq sort grep { $_ ne 'none' } (
        $country_config->{gaming_company}                 // 'none',
        $country_config->{financial_company}              // 'none',
        $country_config->{mt}->{financial}->{standard}[0] // 'none',
        $country_config->{mt}->{financial}->{stp}[0]      // 'none',
        $country_config->{mt}->{gaming}->{standard}[0]    // 'none',
    );

    # Get list of user currencies & landing companies
    my %currencies        = ();
    my @landing_companies = ();
    my $created_at;

    if (@mt5_loginids) {
        my $mt5_real_accounts = $client->user->mt5_logins_with_group('real');
        foreach my $acc (keys $mt5_real_accounts->%*) {
            $mt5_real_accounts->{$acc} =~ m/\\([a-z]+)(_|$)/;
            push @landing_companies, $1 if $1;
        }
    }

    foreach my $sibling (@siblings) {
        my $account = $sibling->account;
        if ($sibling->is_virtual) {
            # created_at should be the date virtual account has been created
            $created_at = $sibling->date_joined;
            # Skip virtual account currency
            next;
        }
        $currencies{$account->currency_code} = 1 if $account && $account->currency_code;
        push @landing_companies, $sibling->landing_company->short;
    }
    # Check DOB existance as virtual account does not have it
    my $client_age;
    if ($client->date_of_birth) {
        my ($year, $month, $day) = split('-', $client->date_of_birth);
        my $dob = Time::Moment->new(
            year  => $year,
            month => $month,
            day   => $day
        );
        # If we get delta between now and DOB it will be negative so do it vice-versa
        $client_age = $dob->delta_years(Time::Moment->now_utc);
    }

    my $has_exclude_until = $client->get_self_exclusion                              ? $client->get_self_exclusion->exclude_until : undef;
    my $unsubscribed      = (not $client->user->email_consent or $has_exclude_until) ? 'true'                                     : 'false';

    return {
        # Reserved traits
        address => {
            street      => $client->address_line_1 . " " . $client->address_line_2,
            town        => $client->address_city,
            state       => $client->state ? BOM::Platform::Locale::get_state_by_id($client->state, $client->residence) : '',
            postal_code => $client->address_postcode,
            country     => Locale::Country::code2country($client->residence),
        },
        age => $client_age,
        #avatar: not_supported,
        birthday => $client->date_of_birth,
        #company: not_supported,
        created_at => Date::Utility->new($created_at)->datetime_iso8601,
        #description: not_supported,
        email      => $client->email,
        first_name => $client->first_name // '',
        #gender     => not_supported for Deriv,
        #id: not_supported,
        last_name => $client->last_name,
        #name: automatically filled
        phone => $client->phone,
        #title: not_supported,
        #username: not_supported,
        #website: website,

        # Custom traits
        country                     => Locale::Country::code2country($client->residence),
        currencies                  => join(',', sort(keys %currencies)),
        mt5_loginids                => join(',', sort(@mt5_loginids)),
        landing_companies           => @landing_companies ? join ',' => uniq sort @landing_companies : 'virtual',
        available_landing_companies => $available_landing_companies,
        provider                    => $provider,
        salutation                  => $client->salutation,

        # subscribe or unsubscribed
        unsubscribed => $unsubscribed,
    };
}

=head2 _validate_event

Check if an event can be sent for the provided/current brand and app id.
Arguments:

=over

=item * C<event> - required. event name.

=item * C<brand> - optional. brand object.

=back

Returns 1 if allowed.

=cut

sub _validate_event {
    my ($event, $brand) = @_;
    $brand //= request->brand;

    unless (_api->write_key) {
        $log->debugf('Write key was not set.');
        return undef;
    }

    unless ($brand->is_track_enabled) {
        $log->debugf('Event tracking is not enabled for brand %s', $brand->name);
        return 0;
    }

    return 1;
}

=head2 _time_to_iso_8601 

Convert the format of the database time to iso 8601 time that is sutable for Segment
Arguments:

=over

=item * C<time> - required. Database time.

=back

=cut

sub _time_to_iso_8601 {
    my $time = shift;
    my ($y_m_d, $h_m_s)          = split(' ', $time);
    my ($year, $month, $day)     = split('-', $y_m_d);
    my ($hour, $minute, $second) = split(':', $h_m_s);
    return Time::Moment->from_epoch(
        Time::Moment->new(
            year   => $year,
            month  => $month,
            day    => $day,
            hour   => $hour,
            minute => $minute,
            second => $second
        )->epoch
    )->to_string;
}

=head2 underage_account_closed

It is triggered for each B<underage_account_closed> event emitted, delivering it to Rudderstack.

=head2 account_with_false_info_locked

It is triggered for each B<account_with_false_info_locked> event emitted, delivering it to Rudderstack.

=head2 account_verification_for_pending_payout

It is triggered for B<vaccount_verification_for_pending_payout> event emitted, delivering it to Rudderstack.

=head2 api_token_created

It is triggered for each B<signup> event emitted, delivering it to Segment.

=head2 api_token_deleted

It is triggered for each B<api_token_delete> event emitted, delivering it to Segment.

=head2 account_reactivated

It is triggered for each B<account_reactivated> event emitted, delivering the data to Segment.

=head2 mt5_password_changed

It is triggered for each B<mt5_password_changed> event emitted, delivering it to Segment.

=head2 app_registered

It is triggered for each B<app_registered> event emitted, delivering it to Segment.

=head2 app_updated

It is triggered for each B<app_updated> event emitted, delivering it to Segment.

=head2 app_deleted

It is triggered for each B<app_deleted> event emitted, delivering it to Segment.

=head2 p2p_archived_ad

Sends to rudderstack a tracking event when an ad is archived.

It takes the following arguments:

=over

=item * C<client> - client instance.

=item * C<adverts> - a B<p2p.p2p_advert> record from database.

=back

=head2 p2p_advert_created

It is triggered for each B<p2p_advert_created> event emitted, delivering it to Segment.

=head2 p2p_advertiser_cancel_at_fault

It is triggered for each B<p2p_advertiser_cancel_at_fault> event emitted, delivering it to Segment.

=head2 p2p_advertiser_temp_banned

It is triggered for each B<p2p_advertiser_temp_banned> event emitted, delivering it to Segment.

=head2 p2p_advertiser_approved

Sends to rudderstack a tracking event when an advertiser becomes age verified.

=head2 payment_deposit

It is triggered for each B<payment_deposit> event emitted, delivering it to Segment.

=head2 payment_withdrawal

It is triggered for each B<payment_withdrawal> event emitted, delivering it to Segment.

=head2 payment_withdrawal_reversal

It is triggered for each B<payment_withdrawal_reversal> event emitted, delivering it to Segment.

=head2 reset_password_request

It is triggered for each B<reset_password_request> event emitted, delivering it to Segment.

=head2 confirm_change_email

It is triggered for each B<change_email tag: update> event emitted, delivering it to Segment.

=head2 verify_change_email

It is triggered for B<change_email tag: verify> event emitted, delivering it to Segment.

=head2 request_change_email

It is triggered for B<verify_email tag: request_email> event emitted, delivering it to Segment.

=head2 reset_password_confirmation

It is triggered for each B<reset_password_confirmation> event emitted, delivering it to Segment.

=head2 age_verified

It is triggered for each B<age_verified> event emitted, delivering it to Segment.

=head2 bonus_approve

It is triggered for each B<bonus_approve> event emitted, delivering it to Segment.

=head2 bonus_reject

It is triggered for each B<bonus_reject> event emitted, delivering it to Segment.

=head2 authenticated_with_scans

It is triggered for each B<authenticated_with_scans> event emitted, delivering it to Segment.

=head2 request_edd_document_upload

It is triggered for B<request_edd_document_upload> event emitted, delivering it to Segment.

=over

=item * C<event> - The event name

=item * C<client> - required. When Client instance

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=head2 crypto_withdrawal_email

It is triggered for each B<crypto_withdrawal_email> event emitted, delivering it to Rudderstack.

=head2 crypto_withdrawal_rejected_email

Send rudderstack event when a crypto payout is rejected

=head2 pa_withdraw_confirm

It is triggered for each B<pa_withdraw_confirm> event emitted, delivering it to Segment.
It can be called with the following parameters:

=head2 pa_transfer_confirm

It is triggered for each B<pa_transfer_confirm> event emitted, delivering it to Segment.

=head2 withdrawal_rejected

It is triggered for each B<withdrawal_rejected> event emitted, delivering it to Segment.

=head2 poi_authentication_requested

It is triggered for each B<poi_authentication_requested> event emitted, delivering it to Segment.

=head2 p2p_order_confirm_verify

It is triggered for each B<p2p_order_confirm_verify> event emitted, delivering it to Segment.

=cut

# generate attribute accessor
for my $event_name (@COMMON_EVENT_METHODS) {
    no strict 'refs';    # allow symbol table manipulation
    *{__PACKAGE__ . '::' . $event_name} = sub {
        my ($args) = @_;
        return track_event(
            event      => $event_name,
            client     => $args->{client},
            loginid    => $args->{loginid},
            properties => $args->{properties} || $args,
        );
        }
        unless __PACKAGE__->can($event_name);
}

1;
