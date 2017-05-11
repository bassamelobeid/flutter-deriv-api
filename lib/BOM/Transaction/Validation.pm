package BOM::Transaction::Validation;

use strict;
use warnings;

use BOM::Database::Helper::RejectedTrade;
use BOM::Platform::Context qw(localize request);
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use Error::Base;
use Format::Util::Numbers qw(commas roundnear to_monetary_number_format);
use LandingCompany::Registry;
use List::Util qw(min max first);
use Moo;
use Postgres::FeedDB::CurrencyConverter qw(amount_from_to_currency);
use YAML::XS qw(LoadFile);

has clients => (
    is       => 'ro',
    required => 1
);
has transaction => (is => 'ro');

################ Client and transaction validation ########################

sub validate_trx_sell {
    my $self = shift;
    ### Client-depended checks
    my $clients = [];
    $clients = $self->transaction->multiple if $self->transaction;
    $clients = [map { +{client => $_} } @{$self->clients}] unless scalar @$clients;

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};
        for (qw/ check_trade_status _validate_iom_withdrawal_limit _validate_available_currency _validate_currency /) {
            my $res = $self->$_($c->{client});
            next unless $res;
            if ($self->transaction && $self->transaction->multiple) {
                $c->{code}  = $res->get_type;
                $c->{error} = $res->{-message_to_client};
                next CLI;
            }
            return $res;
        }
    }
    for (qw/ _is_valid_to_sell _validate_sell_pricing_adjustment _validate_date_pricing /) {
        my $res = $self->$_();
        return $res if $res;
    }
    return;
}

sub validate_trx_buy {
    my $self = shift;
    # all these validations MUST NOT use the database
    # database related validations MUST be implemented in the database
    # ask your friendly DBA team if in doubt
    my $res;
    ### TODO: It's temporary trick for copy trading. Needs to refactor in BOM::Transaction ( remove multiple, change client to clients )
    my $clients = [];
    $clients = $self->transaction->multiple if $self->transaction;
    $clients = [map { +{client => $_} } @{$self->clients}] unless scalar @$clients;

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};
        for (
            qw/
            check_trade_status
            validate_tnc
            _validate_iom_withdrawal_limit
            _validate_available_currency
            _validate_currency
            _validate_jurisdictional_restrictions
            _validate_client_status
            _validate_client_self_exclusion
            _is_valid_to_buy
            /
            )
        {
            $res = $self->$_($c->{client});
            next unless $res;

            if ($self->transaction && $self->transaction->multiple) {
                $c->{code}  = $res->get_type;
                $c->{error} = $res->{-message_to_client};
                next CLI;
            }
            return $res;
        }
    }
    ### Order is very important
    ### _validate_trade_pricing_adjustment may contain some expensive calculations
    #### And last per-client checks must be after this calculations.
    $res = $self->_validate_trade_pricing_adjustment();
    return $res if $res;

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};
        for (qw/ _validate_payout_limit _validate_stake_limit /) {
            $res = $self->$_($c->{client});
            next unless $res;
            if ($self->transaction && $self->transaction->multiple) {
                $c->{code}  = $res->get_type;
                $c->{error} = $res->{-message_to_client};
                next CLI;
            }
            return $res;
        }
    }

    ### we should check pricing time just before DB query
    return $self->_validate_date_pricing();
}

sub _validate_available_currency {
    my ($self, $client) = (shift, shift);

    my $currency = $self->transaction->contract->currency;

    if (not grep { $currency eq $_ } @{LandingCompany::Registry::get_by_broker($client->broker_code)->legal_allowed_currencies}) {
        return Error::Base->cuss(
            -type              => 'InvalidCurrency',
            -mesg              => "Invalid $currency",
            -message_to_client => localize("The provided currency [_1] is invalid.", $currency),
        );
    }
    return;
}

sub _validate_currency {
    my ($self, $client) = (shift, shift);

    my $broker   = $client->broker_code;
    my $currency = $self->transaction->contract->currency;

    if ($client->default_account and $currency ne $client->currency) {
        return Error::Base->cuss(
            -type              => 'NotDefaultCurrency',
            -mesg              => "not default currency for client [$currency], client currency[" . $client->currency . "]",
            -message_to_client => localize("The provided currency [_1] is not the default currency", $currency),
        );
    }

    if (not LandingCompany::Registry::get_by_broker($broker)->is_currency_legal($currency)) {
        return Error::Base->cuss(
            -type              => 'IllegalCurrency',
            -mesg              => "Illegal $currency for $broker",
            -message_to_client => localize("[_1] transactions may not be performed with this account.", $currency),
        );
    }
    return;
}

sub _validate_sell_pricing_adjustment {
    my $self = shift;

    my $contract = $self->transaction->contract;

    if (not defined $self->transaction->price) {
        $self->transaction->price($contract->bid_price);
        return;
    }

    if ($contract->is_expired) {
        return Error::Base->cuss(
            -type              => 'BetExpired',
            -mesg              => 'Contract expired with a new price',
            -message_to_client => localize('The contract has expired'),
        );
    }

    my $currency = $contract->currency;

    my $requested = $self->transaction->price / $self->transaction->payout;
    my ($amount, $recomputed_amount) = ($self->transaction->price, $contract->bid_price);
    # set the requested price and recomputed  price to be store in db
    ### TODO: move out from validation
    $self->transaction->requested_price($amount);
    $self->transaction->recomputed_price($recomputed_amount);
    my $recomputed   = $contract->bid_probability->amount;
    my $move         = $recomputed - $requested;
    my $slippage     = $recomputed_amount - $amount;
    my $allowed_move = $contract->allowed_slippage;

    $allowed_move = 0 if $recomputed == 1;

    return if $move == 0;

    my $final_value;
    if ($allowed_move == 0) {
        $final_value = $recomputed_amount;
    } elsif ($move < -$allowed_move) {
        return $self->_write_to_rejected({
            action            => 'sell',
            amount            => $amount,
            recomputed_amount => $recomputed_amount
        });
    } else {
        if ($move <= $allowed_move and $move >= -$allowed_move) {
            $final_value = $amount;
            # We absorbed the price difference here and we want to keep it in our book.
            $self->transaction->price_slippage($slippage);
        } elsif ($move > $allowed_move) {
            $self->transaction->execute_at_better_price(1);
            # We need to keep record of slippage even it is executed at better price
            $self->transaction->price_slippage($slippage);
            $final_value = $recomputed_amount;
        }
    }

    $self->transaction->price($final_value);

    return;
}

sub _validate_trade_pricing_adjustment {
    my $self = shift;

    my $amount_type = $self->transaction->amount_type;
    my $contract    = $self->transaction->contract;

    my $requested = $self->transaction->price / $self->transaction->payout;
    # set the requested price and recomputed price to be store in db
    $self->transaction->requested_price($self->transaction->price);
    $self->transaction->recomputed_price($contract->ask_price);
    my $recomputed   = $contract->ask_probability->amount;
    my $move         = $requested - $recomputed;
    my $slippage     = $self->transaction->price - $contract->ask_price;
    my $allowed_move = $contract->allowed_slippage;

    $allowed_move = 0 if $recomputed == 1;
    my ($amount, $recomputed_amount) =
        $amount_type eq 'payout' ? ($self->transaction->price, $contract->ask_price) : ($self->transaction->payout, $contract->payout);

    return if $move == 0;

    my $final_value;

    return Error::Base->cuss(
        -type              => 'BetExpired',
        -mesg              => 'Bet expired with a new price[' . $recomputed_amount . '] (old price[' . $amount . '])',
        -message_to_client => localize('The contract has expired'),
    ) if $contract->is_expired;

    if ($allowed_move == 0) {
        $final_value = $recomputed_amount;
    } elsif ($move < -$allowed_move) {
        return $self->_write_to_rejected({
            action            => 'buy',
            amount            => $amount,
            recomputed_amount => $recomputed_amount
        });
    } else {
        if ($move <= $allowed_move and $move >= -$allowed_move) {
            $final_value = $amount;
            # We absorbed the price difference here and we want to keep it in our book.
            $self->transaction->price_slippage($slippage);
        } elsif ($move > $allowed_move) {
            $self->transaction->execute_at_better_price(1);
            # We need to keep record of slippage even it is executed at better price
            $self->transaction->price_slippage($slippage);
            $final_value = $recomputed_amount;
        }
    }

    # adjust the value here
    if ($amount_type eq 'payout') {
        $self->transaction->price($final_value);
    } else {
        $self->transaction->payout($final_value);

        # They are all 'payout'-based when they hit the DB.
        my $new_contract = make_similar_contract(
            $contract,
            {
                amount_type => 'payout',
                amount      => $final_value,
            });
        $self->transaction->contract($new_contract);
    }

    return;
}

sub _write_to_rejected {
    my ($self, $p) = @_;

    my $what_changed = $p->{action} eq 'sell' ? 'sell price' : undef;
    $what_changed //= $self->transaction->amount_type eq 'payout' ? 'price' : 'payout';
    my $market_moved = localize('The underlying market has moved too much since you priced the contract. ');
    my $contract     = $self->transaction->contract;
    $market_moved .= localize(
        'The contract [_4] has changed from [_1][_2] to [_1][_3].',
        $contract->currency,
        to_monetary_number_format($p->{amount}),
        to_monetary_number_format($p->{recomputed_amount}),
        $what_changed
    );

    #Record failed transaction here.
    for my $c (@{$self->clients}) {
        my $rejected_trade = BOM::Database::Helper::RejectedTrade->new({
                login_id => $c->loginid,
                ($p->{action} eq 'sell') ? (financial_market_bet_id => $self->transaction->contract_id) : (),
                shortcode   => $contract->shortcode,
                action_type => $p->{action},
                reason      => 'SLIPPAGE',
                details     => JSON::to_json({
                        order_price      => $self->transaction->price,
                        recomputed_price => $p->{action} eq 'buy' ? $contract->ask_price : $contract->bid_price,
                        slippage         => $self->transaction->price - $contract->ask_price,
                        option_type      => $contract->code,
                        currency_pair    => $contract->underlying->symbol,
                        ($self->transaction->trading_period_start) ? (trading_period_start => $self->transaction->trading_period_start->db_timestamp)
                        : (),
                        ($contract->two_barriers) ? (barriers => $contract->low_barrier->as_absolute . "," . $contract->high_barrier->as_absolute)
                        : (barriers => $contract->barrier->as_absolute),
                        expiry => $contract->date_expiry->db_timestamp,
                        payout => $contract->payout
                    }
                ),
                db => BOM::Database::ClientDB->new({broker_code => $c->broker_code})->db,
            });
        $rejected_trade->record_fail_txn();
    }
    return Error::Base->cuss(
        -type => 'PriceMoved',
        -mesg => "Difference between submitted and newly calculated bet price: currency "
            . $contract->currency
            . ", amount: "
            . $p->{amount}
            . ", recomputed amount: "
            . $p->{recomputed_amount},
        -message_to_client => $market_moved,
    );
}

sub _is_valid_to_buy {
    my ($self, $client) = (shift, shift);
    my $contract = $self->transaction->contract;

    unless ($contract->is_valid_to_buy({landing_company => $client->landing_company->short})) {
        return Error::Base->cuss(
            -type              => 'InvalidtoBuy',
            -mesg              => $contract->primary_validation_error->message,
            -message_to_client => localize($contract->primary_validation_error->message_to_client));
    }

    return;
}

sub _is_valid_to_sell {
    my $self     = shift;
    my $contract = $self->transaction->contract;

    if (not $contract->is_valid_to_sell) {
        return Error::Base->cuss(
            -type              => 'InvalidtoSell',
            -mesg              => $contract->primary_validation_error->message,
            -message_to_client => localize($contract->primary_validation_error->message_to_client));
    }

    return;
}

sub _validate_date_pricing {
    my $self     = shift;
    my $contract = $self->transaction->contract;

    if (not $contract->is_expired
        and abs(time - $contract->date_pricing->epoch) > 20)
    {
        return Error::Base->cuss(
            -type              => 'InvalidDatePricing',
            -mesg              => 'Bet was validated for a time [' . $contract->date_pricing->epoch . '] too far from now[' . time . ']',
            -message_to_client => localize('This contract cannot be properly validated at this time.'));
    }
    return;
}

=head2 $self->_validate_iom_withdrawal_limit

Validate the withdrawal limit for IOM region

=cut

sub _validate_iom_withdrawal_limit {
    my $self   = shift;
    my $client = shift;

    return if $client->is_virtual;

    my $landing_company = LandingCompany::Registry::get_by_broker($client->broker_code);
    return if ($landing_company->country ne 'Isle of Man');

    my $payment_limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'));

    my $landing_company_short = $landing_company->short;
    my $withdrawal_limits     = $payment_limits->{withdrawal_limits};
    my $numdays               = $withdrawal_limits->{$landing_company_short}->{for_days};
    my $numdayslimit          = $withdrawal_limits->{$landing_company_short}->{limit_for_days};
    my $lifetimelimit         = $withdrawal_limits->{$landing_company_short}->{lifetime_limit};

    if ($client->client_fully_authenticated) {
        $numdayslimit  = 99999999;
        $lifetimelimit = 99999999;
    }

    # withdrawal since $numdays
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
    my $withdrawal_in_days = $payment_mapper->get_total_withdrawal({
        start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
        exclude    => ['currency_conversion_transfer'],
    });
    $withdrawal_in_days = roundnear(0.01, amount_from_to_currency($withdrawal_in_days, $client->currency, 'EUR'));

    # withdrawal since inception
    my $withdrawal_since_inception = $payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']});
    $withdrawal_since_inception = roundnear(0.01, amount_from_to_currency($withdrawal_since_inception, $client->currency, 'EUR'));

    my $remaining_withdrawal_eur =
        roundnear(0.01, min(($numdayslimit - $withdrawal_in_days), ($lifetimelimit - $withdrawal_since_inception)));

    if ($remaining_withdrawal_eur <= 0) {
        return Error::Base->cuss(
            -type => 'iomWithdrawalLimit',
            -mesg => $client->loginid . ' caught in IOM withdrawal limit check',
            -message_to_client =>
                localize("Due to regulatory requirements, you are required to authenticate your account in order to continue trading."),
        );
    }
    return;
}

# This validation should always come after _validate_trade_pricing_adjustment
# because we recompute the price and that's the price that we going to transact with!
sub _validate_stake_limit {
    my $self     = shift;
    my $client   = shift;
    my $contract = $self->transaction->contract;

    my $landing_company = $client->landing_company;
    my $currency        = $contract->currency;

    my $stake_limit =
        $landing_company->short eq 'maltainvest'
        ? BOM::Platform::Config::quants->{bet_limits}->{min_stake}->{maltainvest}->{$currency}
        : $contract->staking_limits->{min};    # minimum is always a stake check

    if ($contract->ask_price < $stake_limit) {
        return Error::Base->cuss(
            -type => 'StakeTooLow',
            -mesg => $client->loginid . ' stake [' . $contract->ask_price . '] is lower than minimum allowable stake [' . $stake_limit . ']',
            -message_to_client => localize(
                "This contract's price is [_1][_2]. Contracts purchased from [_3] must have a purchase price above [_1][_4]. Please accordingly increase the contract amount to meet this minimum stake.",
                $currency,
                to_monetary_number_format($contract->ask_price),
                $landing_company->name,
                to_monetary_number_format($stake_limit)
            ),
        );
    }
    return;
}

=head2 $self->_validate_payout_limit

Validate if payout is not over the client limits

=cut

sub _validate_payout_limit {
    my ($self, $client) = (shift, shift);

    my $contract = $self->transaction->contract;

    my $rp = $contract->risk_profile;
    my @cl_rp = $rp->get_client_profiles($client->loginid, $client->landing_company->short);

    # setups client specific payout and turnover limits, if any.
    if (@cl_rp) {
        my $custom_profile = $rp->get_risk_profile(\@cl_rp);
        if ($custom_profile eq 'no_business') {
            return Error::Base->cuss(
                -type              => 'NoBusiness',
                -mesg              => $client->loginid . ' manually disabled by quants',
                -message_to_client => localize('This contract is unavailable on this account.'),
            );
        }

        my $custom_limit = BOM::Platform::Config::quants->{risk_profile}{$custom_profile}{payout}{$contract->currency};
        if (defined $custom_limit and (my $payout = $self->transaction->payout) > $custom_limit) {
            return Error::Base->cuss(
                -type              => 'PayoutLimitExceeded',
                -mesg              => $client->loginid . ' payout [' . $payout . '] over custom limit[' . $custom_limit . ']',
                -message_to_client => ($custom_limit == 0)
                ? localize('This contract is unavailable on this account.')
                : localize('This contract is limited to ' . to_monetary_number_format($custom_limit) . ' payout on this account.'),
            );
        }
    }

    return;
}

=head2 $self->_validate_jurisdictional_restrictions

Validates whether the client has provided his residence country

=cut

sub _validate_jurisdictional_restrictions {
    my ($self, $client) = (shift, shift);

    my $contract    = $self->transaction->contract;
    my $residence   = $client->residence;
    my $loginid     = $client->loginid;
    my $market_name = $contract->market->name;

    if (!$residence && $loginid !~ /^VR/) {
        return Error::Base->cuss(
            -type => 'NoResidenceCountry',
            -mesg => 'Client cannot place contract as we do not know their residence.',
            -message_to_client =>
                localize('In order for you to place contracts, we need to know your Residence (Country). Please update your settings.'),
        );
    }

    my $lc = LandingCompany::Registry::get_by_broker($loginid);

    my %legal_allowed_ct = map { $_ => 1 } @{$lc->legal_allowed_contract_types};
    if (not $legal_allowed_ct{$contract->code}) {
        return Error::Base->cuss(
            -type              => 'NotLegalContractCategory',
            -mesg              => 'Clients are not allowed to trade on this contract category as its restricted for this landing company',
            -message_to_client => localize('Please switch accounts to trade this contract.'),
        );
    }

    if (not grep { $market_name eq $_ } @{$lc->legal_allowed_markets}) {
        return Error::Base->cuss(
            -type              => 'NotLegalMarket',
            -mesg              => 'Clients are not allowed to trade on this markets as its restricted for this landing company',
            -message_to_client => localize('Please switch accounts to trade this market.'),
        );
    }

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    if ($residence && $market_name eq 'volidx' && $countries_instance->volidx_restricted_country($residence)) {
        return Error::Base->cuss(
            -type              => 'RandomRestrictedCountry',
            -mesg              => 'Clients are not allowed to place Volatility Index contracts as their country is restricted.',
            -message_to_client => localize('Sorry, contracts on Volatility Indices are not available in your country of residence'),
        );
    }

    # For certain countries such as Belgium, we are not allow to sell financial product to them.
    if (   $residence
        && $market_name ne 'volidx'
        && $countries_instance->financial_binaries_restricted_country($residence))
    {
        return Error::Base->cuss(
            -type              => 'FinancialBinariesRestrictedCountry',
            -mesg              => 'Clients are not allowed to place financial products contracts as their country is restricted.',
            -message_to_client => localize('Sorry, contracts on Financial Products are not available in your country of residence'),
        );
    }

    my %legal_allowed_underlyings = map { $_ => 1 } @{$lc->legal_allowed_underlyings};
    if (not $legal_allowed_underlyings{all} and not $legal_allowed_underlyings{$contract->underlying->symbol}) {
        return Error::Base->cuss(
            -type              => 'NotLegalUnderlying',
            -mesg              => 'Clients are not allowed to trade on this underlying as its restricted for this landing company',
            -message_to_client => localize('Please switch accounts to trade this underlying.'),
        );
    }

    return;
}

=head2 $self->_validate_client_status

Validates to make sure that the client with unwelcome status
is not able to purchase contract

=cut

sub _validate_client_status {
    my ($self, $client) = (shift, shift);

    if ($client->get_status('unwelcome') or $client->get_status('disabled')) {
        return Error::Base->cuss(
            -type              => 'ClientUnwelcome',
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize('Sorry, your account is not authorised for any further contract purchases.'),
        );
    }

    return;
}

=head2 $self->_validate_client_self_exclusion

Validates to make sure that the client with self exclusion
is not able to purchase contract

=cut

sub _validate_client_self_exclusion {
    my ($self, $client) = (shift, shift);

    if (my $limit_excludeuntil = $client->get_self_exclusion_until_dt) {
        return Error::Base->cuss(
            -type              => 'ClientSelfExcluded',
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize('Sorry, you have excluded yourself from the website until [_1].', $limit_excludeuntil),
        );
    }

    return;
}

################ Client only validation ########################

sub validate_tnc {
    my ($self, $client) = (shift, shift);

    # we shouldn't get to this error, so we can die it directly
    return if $client->is_virtual;

    my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
    my $client_tnc_status   = $client->get_status('tnc_approval');
    if (not $client_tnc_status or ($client_tnc_status->reason ne $current_tnc_version)) {
        return Error::Base->cuss(
            -type              => 'ASK_TNC_APPROVAL',
            -mesg              => 'Terms and conditions approval is required',
            -message_to_client => localize('Terms and conditions approval is required.'),
        );
    }

    return;
}

sub compliance_checks {
    my ($self, $client) = (shift, shift);

    # checks are not applicable for virtual, costarica and champion clients
    return if $client->is_virtual;
    return if $client->landing_company->short =~ /^(?:costarica|champion)$/;

    # as per compliance for high risk client we need to check
    # if financial assessment details are completed or not
    if (($client->aml_risk_classification // '') eq 'high' and not $client->financial_assessment()) {
        return Error::Base->cuss(
            -type              => 'FinancialAssessmentRequired',
            -mesg              => 'Please complete the financial assessment form to lift your withdrawal and trading limits.',
            -message_to_client => localize('Please complete the financial assessment form to lift your withdrawal and trading limits.'),
        );
    }

    return;
}

sub check_tax_information {
    my ($self, $client) = (shift, shift);

    if ($client->landing_company->short eq 'maltainvest' and not $client->get_status('crs_tin_information')) {
        return Error::Base->cuss(
            -type => 'TINDetailsMandatory',
            -mesg => 'Tax-related information is mandatory for legal and regulatory requirements',
            -message_to_client =>
                localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'));
    }
    return;
}

# don't allow to trade for unwelcome_clients
# and for MLT and MX we don't allow trading without confirmed age
sub check_trade_status {
    my ($self, $client) = (shift, shift);

    return if $client->is_virtual;
    return $self->not_allow_trade($client);
}

=head2 allow_paymentagent_withdrawal

to check client can withdrawal through payment agent. return 1 (allow) or undef (denied)

=cut

sub allow_paymentagent_withdrawal {
    my ($self, $client) = (shift, shift);

    my $expires_on = $client->payment_agent_withdrawal_expiration_date;

    if ($expires_on) {
        return 1 if Date::Utility->new($expires_on)->is_after(Date::Utility->new);
    } else {
        # if expiry date is not set check for doughflow count
        my $payment_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => $client->loginid});
        my $doughflow_count = $payment_mapper->get_client_payment_count_by({payment_gateway_code => 'doughflow'});
        return 1 if $doughflow_count == 0;
    }
    return;
}

=head2 not_allow_trade

Check if client is allowed to trade.

Don't allow to trade for unwelcome_clients and for MLT and MX without confirmed age

=cut

sub not_allow_trade {
    my ($self, $client) = (shift, shift);

    if (   (($client->landing_company->short =~ /^(?:malta|iom)$/) and not $client->get_status('age_verification') and $client->has_deposits)
        or $client->get_status('unwelcome')
        or $client->get_status('disabled'))
    {
        return Error::Base->cuss(
            -type              => 'PleaseContactSupport',
            -mesg              => 'Please contact customer support for more information.',
            -message_to_client => localize('Please contact customer support for more information.'),
        );
    }
    return;
}

1;
