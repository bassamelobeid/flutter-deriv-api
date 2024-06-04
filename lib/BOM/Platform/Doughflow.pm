package BOM::Platform::Doughflow;

=head1 NAME

BOM::Platform::Doughflow

=head1 DESCRIPTION

A collection of static methods that related to the front-end of
our Doughflow integration.

=cut

use strict;
use warnings;

use JSON::MaybeXS;
use List::MoreUtils            qw(any uniq);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Time::Moment;

use BOM::Config;
use BOM::Config::Runtime;
use Brands;
use LandingCompany::Registry;

use base qw( Exporter );
our @EXPORT_OK = qw(
    get_doughflow_language_code_for
    get_payment_methods
    get_sportsbook_for_client
);

=head2 get_doughflow_language_code_for

Maps a given language code to Doughflow/Premier Cashier specific language code.

B<Note> if no mapping is found it defaults to English (en)

=over 4

=item * C<lang> -  A string with the two characters language code.

=back

Returns language code as required by Doughflow/Premier Cashier.

=cut

sub get_doughflow_language_code_for {
    my $lang = shift;

    # mapping b/w out lang code and doughflow code
    my %lang_code_for = (
        ZH_CN => 'zh_CHS',
        ZH_TW => 'zh_CHT',
        JA    => 'jp'
    );

    my $code = 'en';
    $lang = uc $lang;

    if (exists $lang_code_for{$lang}) {
        $code = $lang_code_for{$lang};
    } elsif (grep { $_ eq $lang } @{BOM::Config::Runtime->instance->app_config->cgi->allowed_languages}) {
        $code = lc $lang;
    }

    return $code;
}

=head2 get_sportsbook_for_client

Given a client, returns the sportsbook name (or frontend name in Doughflow/PremierCashier jargon)

Arguments:

=over 4

=item * C<client> - Client object

=back

Returns a sportsbook name.

=cut

sub get_sportsbook_for_client {
    my $client = shift;

    # clients who are wallets and don't have pin mapping should use WLT sportsbook
    my $is_wallet = $client->is_wallet && $client->doughflow_pin eq $client->loginid;

    return get_sportsbook(
        landing_company => $client->landing_company->short,
        currency        => $client->currency,
        is_wallet       => $is_wallet,
    );
}

=head2 get_sportsbook

Get doughflow sportsbook name by args.

Takes the following named arguments:

=over 4

=item * C<landing_company> - landing company short code

=item * C<currency> - uppercase currency code

=item * C<is_wallet> - get wallet sportsbook when true, otherwise non-wallet sportsbook

=back

Returns a sportsbook name or empty string.

=cut

sub get_sportsbook {
    my %args = @_;

    my $config          = BOM::Config::cashier_config()->{doughflow}{sportsbooks};
    my $landing_company = $args{landing_company};
    my $wallet_key      = $args{is_wallet} ? 'wallet' : 'non-wallet';
    my $sportsbook      = $config->{$landing_company}{$wallet_key} // die "no sportsbook found for $landing_company ($wallet_key)";

    unless (BOM::Config::on_production()) {
        my $cashier_env = BOM::Config::cashier_env();
        $sportsbook =~ s/^Deriv\b/$cashier_env/;
    }

    return $sportsbook . ' ' . $args{currency};
}

=head2 get_payment_methods

Returns payment methods available in Doughflow, optionally filtered by
the country received as parameter.

Parameters supported:

=over 4

=item * C<country> - A string with the country as two letter code (ISO 3166-Alpha2).

=item * C<brand> - A string describing the brand. Defaults to 'deriv'

=back

Returns a list of payment methods, as an array ref.

The elements in the array have the following fields

=over 4


=item * C<deposit_limts> - A hash ref with the deposit limits for this payment method.

=item * C<deposit_time> - A string describing how much time takes a deposit to be processed en visible in clients account.

=item * C<description> - A string describing this payment method.

=item * C<display_name> - A string with an user friendly representation of this payment method name.

=item * C<id> - A string to identify the payment method.

=item * C<payment_processor> - A string with the payment processor name if there is one. This could be an empty string.

=item * C<predefined_amount> - An array ref with the predefined amounts to deposit/withdraw.

=item * C<signup_link> - A string with the link for signup with this payment method.

=item * C<supported_currencies> - An array ref with currencies supported as 3-letter representation.

=item * C<type_display_name> - A string with an user friendly representation of the type of payment method.

=item * C<type> - A string describing the type of payment method. Can be one of B<Ewallet>, B<CreditCard>.

=item * C<withdrawal_limits> - A hash ref with the withdrawal limits for this payment method.

=item * C<withdrawal_time> - A string with a description of how much time takes a withdrawal request to be processed.

=back

Every C<deposit_limits> or C<withdraw_limits> hashref have the following structure. A string key with the 3-letter currency code, e.g. B<USD>, B<EUR>. The attributes for this hash ref are:

=over 4

=item * C<min> - Minimum amount of money required to deposit/whitdraw.

=item * C<max> - Maximum amount of money required to deposit/whitdraw.

=back

=cut

sub get_payment_methods {
    my $country = shift;
    my $brand   = shift;

    my $start = Time::Moment->now;

    my $redis_payment = BOM::Config::Redis::redis_payment();

    # Get the Country or countries.
    my @short_codes;
    if ($country) {
        my $country_details = Brands->new(name => $brand)->countries_instance->countries_list->{$country};
        die "Unknown country code" unless $country_details;
        @short_codes = @{$country_details}{qw/financial_company gaming_company/};
    } else {
        my %all_countries = Brands->new(name => $brand)->countries_instance->countries_list->%*;
        push @short_codes, @{$all_countries{$_}}{qw/financial_company gamming_company/} for keys %all_countries;
    }
    @short_codes = uniq grep { $_ && ($_ ne 'none') } @short_codes;
    return [] unless scalar @short_codes;

    # Just getting the sportsbooks
    my @landing_companies =
        map { LandingCompany::Registry->by_name($_) } @short_codes;

    my @sportsbook_names = ();
    for my $lc (@landing_companies) {
        my $currencies = $lc->legal_allowed_currencies;
        for my $currency (keys %$currencies) {
            if ($currencies->{$currency}->{type} eq 'fiat') {
                push @sportsbook_names,
                    get_sportsbook(
                    landing_company => $lc->short,
                    currency        => $currency
                    );
                if (my $wallet_sportsbook = get_sportsbook(landing_company => $lc->short, currency => $currency, is_wallet => 1)) {
                    push @sportsbook_names, $wallet_sportsbook;
                }
            }
        }
    }
    @sportsbook_names = uniq @sportsbook_names;    # All the required sportsbooks.

    # Getting the payment keys from redis.
    my $time_to_get_pm_keys = Time::Moment->now;
    my @redis_keys          = _get_all_payment_keys($redis_payment, $country);
    stats_timing(
        'bom.platform.doughflow.get_payment_keys.timing',
        $time_to_get_pm_keys->delta_milliseconds(Time::Moment->now),
        {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a')]});

    # Getting data from Redis.
    my $get_redis_data  = Time::Moment->now;
    my $payment_methods = {};
    for my $key (@redis_keys) {
        my $payment_method = decode_json($redis_payment->get($key));
        $payment_methods->{$payment_method->{frontend_name}} = $payment_method
            if grep { uc $_ eq uc $payment_method->{frontend_name} } @sportsbook_names;
    }
    stats_timing(
        'bom.platform.doughflow.get_redis_data.timing',
        $get_redis_data->delta_milliseconds(Time::Moment->now),
        {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a'), 'keys_count:' . scalar @redis_keys]});

    # Building the payment method structure
    my $building_time = Time::Moment->now;
    my $response      = {};
    for my $frontend_name (keys %$payment_methods) {
        my ($deposit_options, $payout_options, $base_currency) =
            @{$payment_methods->{$frontend_name}}{"deposit_options", "payout_options", "base_currency"};
        next unless (scalar @$deposit_options) + (scalar @$payout_options);

        $deposit_options = _filter_payment_methods($deposit_options, $country);
        $payout_options  = _filter_payment_methods($payout_options,  $country);

        my $deposit_building = Time::Moment->now;
        for my $deposit (@$deposit_options) {
            my $payment_method =
                ($response->{$deposit->{payment_method}} //= {});
            my $limits = ($payment_method->{deposit_limits} //= {});
            $payment_method->{id}                = $deposit->{payment_method};
            $payment_method->{display_name}      = $deposit->{payment_method};
            $payment_method->{description}       = $deposit->{payment_method};
            $payment_method->{payment_processor} = $deposit->{payment_processor};
            $payment_method->{type}              = $deposit->{payment_type};
            $payment_method->{type_display_name} = $deposit->{payment_type};        # For now we don't have a friendly name for this

            $limits->{$base_currency} = {
                min => $deposit->{minimum_amount},
                max => $deposit->{maximum_amount}};

            $payment_method->{deposit_time} = 'instant';
        }
        stats_timing(
            'bom.platform.doughflow.deposit_building.timing',
            $deposit_building->delta_milliseconds(Time::Moment->now),
            {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a'), 'deposit_options:' . scalar @$deposit_options]});

        my $payout_building = Time::Moment->now;
        for my $payout (@$payout_options) {
            my $payment_method =
                ($response->{$payout->{payment_method}} //= {});
            my $limits = ($payment_method->{withdraw_limits} //= {});

            $payment_method->{id}                = $payout->{payment_method};
            $payment_method->{type}              = $payout->{payment_type};
            $payment_method->{type_display_name} = $payout->{payment_type};        # For now we don't have a friendly name for this
            $payment_method->{display_name}      = $payout->{friendly_name};
            $payment_method->{description}       = $payout->{friendly_name};
            $payment_method->{payment_processor} = $payout->{payment_processor};
            $limits->{$base_currency}            = {
                min => $payout->{minimum_amount},
                max => $payout->{maximum_amount}};

            $payment_method->{withdrawal_time}    = $payout->{time_frame};
            $payment_method->{description}        = q{};
            $payment_method->{predefined_amounts} = [5, 10, 100, 300, 500];
            $payment_method->{signup_link}        = q{};
            $payment_method->{supported_currencies} //= [];
            push $payment_method->{supported_currencies}->@*, $base_currency;
            $payment_method->{supported_currencies} =
                [uniq $payment_method->{supported_currencies}->@*];
        }
        stats_timing(
            'bom.platform.doughflow.payout_building.timing',
            $payout_building->delta_milliseconds(Time::Moment->now),
            {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a'), 'payout_options:' . scalar @$payout_options]});
    }
    stats_timing(
        'bom.platform.doughflow.buiding_pm.timing',
        $building_time->delta_milliseconds(Time::Moment->now),
        {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a'), 'payment_methods_count:' . scalar keys %$payment_methods]});

    # Normalizing the rest of fields.
    for my $id (keys %$response) {
        my $payment_method = $response->{$id};
        $payment_method->{deposit_limits} //= {};
        $payment_method->{deposit_time} = 'instant';
        $payment_method->{description}       //= '';
        $payment_method->{display_name}      //= '';
        $payment_method->{payment_processor} //= '';
        $payment_method->{predefined_amounts} = [5, 10, 100, 300, 500];
        $payment_method->{signup_link}          //= '';
        $payment_method->{supported_currencies} //= [];
        $payment_method->{type_display_name}    //= '';
        $payment_method->{type}                 //= '';
        $payment_method->{withdraw_limits}      //= {};
        $payment_method->{withdrawal_time}      //= '';

    }

    my $ret = [];

    push @$ret, $response->{$_} for sort keys %$response;

    stats_timing(
        'bom.platform.doughflow.payment_methods.timing',
        $start->delta_milliseconds(Time::Moment->now),
        {tags => ['country:' . ($country || 'all'), 'brand:' . ($brand || 'n/a')]});

    return $ret;
}

=head2 _get_all_payment_keys

Get all the payment method keys in redis payments for a given country.

Arguments:

=over 4

=item * C<redis> - A ref for the redis payment client.

=item * C<country> - A string with the country code. (optional)

=back

It returns an ARRAY of strings with all the payment method keys found for the
given country.

If no country is passed all the payment method keys are returned.

=cut

sub _get_all_payment_keys {
    my $redis   = shift;
    my $country = shift;
    my $regex   = 'DERIV::CASHIER::PAYMENT_METHODS::.*::' . ($country ? uc $country : '[A-Z]{2}');
    my @res;

    my $cursor = 0;
    do {
        ($cursor, my $keys) = $redis->scan($cursor)->@*;
        push @res, grep { /$regex/ } $keys->@*;
    } while ($cursor);

    return @res;
}

=head2 _filter_payment_methods

Filter the payment methods following some business rules.

should receive two arguments. The first is an array ref with payment methods (payout
or deposit options), and the second is an scalar B<country> with the country code,
it can be undefined.

It is expected that every hashref have the following attributes:

=over 4

=item * C<processor_enabled> - A number, acting as boolean 1 for true, 0 for false.  Determines if the processor was enabled.

=item * C<blocked> - A number, acting as boolean. Determines if the payment method is blocked.

=item * C<geo_blocked> - A number, acting as boolean. Determines if payment method is blockef for some geographical reason. Only relevant when country is not null

=item * C<payment_type> - A string describing what kind of payment type it is.

=item * C<processor_type> - A string describing the processor type.

=item * C<payment_method> - A string describing the payment method name.

=back

Returns an array ref to the filtered list of payout or deposit methods.

=cut

sub _filter_payment_methods {
    my @payment_methods = shift->@*;
    my $country         = shift;
    # Doughflow is not used for Crypto processing.
    # Manual types is mostly performed by PayOps team should be not offered.
    # CFT and BankWire are hided by bussiness requirements.
    my @ignored_payment_types   = qw( CryptoCurrency Manual );
    my @ignored_processor_types = qw( CryptoCurrency );
    my @ignored_payment_methods = qw ( CFT BankWire );

    @payment_methods =
        grep { (!defined $_->{processor_enabled} || $_->{processor_enabled}) && !$_->{blocked} && !($country && $_->{geo_blocked}) } @payment_methods;

    my @ret = ();
    for my $payment_method (@payment_methods) {
        next if (any { $_ eq ($payment_method->{payment_type}   // '') } @ignored_payment_types);
        next if (any { $_ eq ($payment_method->{processor_type} // '') } @ignored_processor_types);
        next if (any { $_ eq ($payment_method->{payment_method} // '') } @ignored_payment_methods);
        push @ret, $payment_method;
    }

    return \@ret;

}

1;
