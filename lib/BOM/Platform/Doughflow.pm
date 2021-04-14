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
use List::MoreUtils qw(any uniq);

use BOM::Config;
use BOM::Config::Runtime;
use Brands;
use LandingCompany::Registry;

use base qw( Exporter );
our @EXPORT_OK = qw(
    get_doughflow_language_code_for
    get_payment_methods
    get_sportsbook
);

=head2 get_sportsbook_by_short_code

Given a Landing Company short code and a currency code, returns the sportsbook name (or frontend name in Doughflow/PremierCashier jargon)

=over 4

=item * C<short_code> -  A string with the landing company short code.

=item * C<currency> - Currency code in ISO 4217 (three letter code).

=back

Returns a string with the Sportsbook name.

=cut

sub get_sportsbook_by_short_code {
    my ($short_code, $currency) = @_;

    if (not BOM::Config::on_production()) {
        return 'test';
    }

    return get_sportsbook_mapping_by_landing_company($short_code) . ' ' . $currency
        if is_deriv_sportsbooks_enabled();

    # TODO: remove this check once Doughflow's side is live
    # for backward compatibility, we keep sportsbook prefixes as 'Binary'
    my %mapping = (
        svg         => 'Binary (CR) SA',
        malta       => 'Binary (Europe) Ltd',
        iom         => 'Binary (IOM) Ltd',
        maltainvest => 'Binary Investments Ltd',
    );

    return $mapping{$short_code} . ' ' . $currency;
}

=head2 get_sportsbook

Given a broker code and a currency code, returns the sportsbook name (or frontend name in Doughflow/PremierCashier jargon)

=over 4

=item * C<broker> -  A string with the broker code.

=item * C<currency> - Currency code in ISO 4217 (three letter code).

=back

Returns  a string with the Sportsbook name.

=cut

sub get_sportsbook {
    my ($broker, $currency) = @_;

    my $landing_company = LandingCompany::Registry->get_by_broker($broker);

    return get_sportsbook_by_short_code($landing_company->{short}, $currency);
}

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

=head2 is_deriv_sportsbooks_enabled
Returns true if doughflow Deriv sportsbooks are enabled, false otherwise
=cut

# TODO: remove this check once Doughflow's side is live
sub is_deriv_sportsbooks_enabled {
    my $self = shift;

    # is doughflow Deriv sportsbook enabled?
    return !BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks;
}

=head2 get_sportsbook_mapping_by_landing_company

Get doughflow sportsbook name for a landing company.

Takes the following argument:

=over 4

=item * C<landing_company_shortcode> - short code of landing company

=back

Returns a sportsbook name corresponding to the landing company

=cut

sub get_sportsbook_mapping_by_landing_company {
    my $landing_company_shortcode = shift;

    my %mapping = (
        svg         => 'Deriv (SVG) LLC',
        malta       => 'Deriv (Europe) Ltd',
        iom         => 'Deriv (MX) Ltd',
        maltainvest => 'Deriv Investments Ltd'
    );

    return $mapping{$landing_company_shortcode} // '';
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

=item * C<withdrawal_limits> - A hash ref with the deposit limits for this payment method.

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

    my $redis_payment = BOM::Config::Redis::redis_payment();

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

    my @landing_companies =
        map { LandingCompany::Registry::get $_ } @short_codes;

    my @sportsbook_names = ();
    for my $lc (@landing_companies) {
        my $currencies = $lc->legal_allowed_currencies;
        for my $currency (keys %$currencies) {
            if ($currencies->{$currency}->{type} eq 'fiat') {
                push @sportsbook_names, get_sportsbook_by_short_code($lc->{short}, $currency);
            }
        }
    }
    @sportsbook_names = uniq @sportsbook_names;

    my @redis_keys = _get_all_payment_keys($redis_payment, $country);

    my $payment_methods = {};
    for my $key (@redis_keys) {
        my $payment_method = decode_json($redis_payment->get($key));
        $payment_methods->{$payment_method->{frontend_name}} = $payment_method
            if grep { uc $_ eq uc $payment_method->{frontend_name} } @sportsbook_names;
    }

    my $response = {};
    for my $frontend_name (keys %$payment_methods) {
        my ($deposit_options, $payout_options, $base_currency) =
            @{$payment_methods->{$frontend_name}}{"deposit_options", "payout_options", "base_currency"};
        next unless (scalar @$deposit_options) + (scalar @$payout_options);

        $deposit_options = _filter_payment_methods($deposit_options, $country);
        $payout_options  = _filter_payment_methods($payout_options,  $country);

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
    }

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
    my $regex   = 'DERIV::CASHIER::PAYMENT_METHODS::.*::' . ($country ? uc $country : q{@});
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
        next if (any { $_ eq $payment_method->{payment_type} } @ignored_payment_types);
        next if (any { $_ eq $payment_method->{processor_type} } @ignored_processor_types);
        next if (any { $_ eq $payment_method->{payment_method} } @ignored_payment_methods);
        push @ret, $payment_method;
    }

    return \@ret;

}

1;
