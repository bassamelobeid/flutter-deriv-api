package BOM::Transaction::Validation;

use strict;
use warnings;

use Moo;
use Error::Base;
use List::Util qw(min max first any);
use YAML::XS   qw(LoadFile);
use JSON::MaybeXS;

use Business::Config::LandingCompany;

use BOM::Config::Quants              qw(get_exchangerates_limit);
use Format::Util::Numbers            qw/financialrounding/;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::Database::Helper::RejectedTrade;
use BOM::Platform::Context        qw(localize request);
use BOM::Product::ContractFactory qw( produce_contract );
use Locale::Country::Extra;
use BOM::Database::ClientDB;
use Date::Utility;
use BOM::Config;
use BOM::Transaction::Utility;

has clients => (
    is       => 'ro',
    required => 1
);

has transaction => (is => 'ro');

=head2 trade_adjusted

A boolean to indicate if comaparison of requested vs recalculated has been done

=cut

has trade_adjusted => (
    is      => 'rw',
    default => 0,
);

my $json = JSON::MaybeXS->new;
################ Client and transaction validation ########################

sub validate_trx_cancel {
    my $self = shift;

    my $contract = $self->transaction->contract;

    unless ($contract->is_valid_to_cancel) {
        my $error = $contract->primary_validation_error;

        return Error::Base->cuss(
            -type              => 'CancelFailed',
            -mesg              => $error->message,
            -message_to_client => localize($error->message_to_client),
        );
    }

    $self->transaction->price($contract->cancel_price);
    return undef;
}

sub validate_trx_sell {
    my $self = shift;
    ### Client-depended checks
    my $clients = $self->clients;

    my @extra_validation_methods = qw/ _validate_offerings_sell /;

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};

        my $client            = $c->{client};
        my @validation_checks = (@{$client->landing_company->transaction_checks}, @extra_validation_methods);

        foreach my $method (@validation_checks) {

            my $res = $self->$method($client);
            next unless $res;

            if ($self->transaction && $self->transaction->multiple) {
                $c->{code}  = $res->get_type;
                $c->{error} = $res->{-message_to_client};
                next CLI;
            }

            return $res;
        }
    }

    my @contract_validation_method = qw/_is_valid_to_sell _validate_sell_pricing_adjustment _validate_date_pricing/;

    foreach my $c_method (@contract_validation_method) {
        my $res = $self->$c_method();

        return $res if $res;
    }
    return undef;
}

=head2 validate_trx_batch_buy

Validate identical contract purchase for multiple clients.

=cut

sub validate_trx_batch_buy {
    my $self = shift;

    CLI: for my $c ($self->clients->@*) {
        if ($c->{client} and my $error = $self->validate_trx_buy($c->{client})) {
            if ($self->_bailout_early($error)) {
                return $error;
            } else {
                $c->{code}  = $error->get_type;
                $c->{error} = $error->{-message_to_client};
                next CLI;
            }
        }
    }
}

=head2 _bailout_early

If contract is invalid in batch buy, exit early.

Returns boolean.

=cut

sub _bailout_early {
    my ($self, $error) = @_;

    my $type = $error->get_type;
    # contract related error, bailout now
    if ($type eq 'InvalidDatePricing' or $type eq 'BetExpired' or $type eq 'PriceMoved' or $type eq 'InvalidtoBuy') {
        return 1;
    }

    my $message = $error->get_mesg;
    if ($type eq 'InvalidOfferings' and ($message eq 'Invalid underlying symbol' or $message eq 'Invalid contract category')) {
        return 1;
    }

    return 0;
}

=head2 validate_trx_buy

Validate contract purchase for a single client.

=cut

sub validate_trx_buy {
    my ($self, $client) = @_;
    # all these validations MUST NOT use the database
    # database related validations MUST be implemented in the database
    # ask your friendly DBA team if in doubt

    $client //= $self->transaction->client;
    my @transaction_checks = $client->landing_company->transaction_checks->@*;

    my @extra_validation_methods = qw/
        _validate_offerings_buy
        _is_valid_to_buy
        _validate_trade_pricing_adjustment
        _validate_no_volume_limit
        _validate_payment_agent_restriction
        /;

    push @extra_validation_methods, qw(
        _validate_payout_limit
        _validate_stake_limit);

    # We should check pricing time just before DB query. So check this last!
    push @extra_validation_methods, '_validate_date_pricing';

    my @validation_checks = (@transaction_checks, @extra_validation_methods);

    foreach my $method (@validation_checks) {
        if (my $error = $self->$method($client)) {
            return $error;
        }
    }

    return undef;
}

=head2 _validate_payment_agent_restriction

Checks if the trading service is avaiable (only if the client is an authorized payment agent).
This rule is implemented in bom-rules; but because of circular dependencies it cannot be invoked here.

=cut

sub _validate_payment_agent_restriction {
    my ($self, $client) = @_;

    my $pa = $client->get_payment_agent or return undef;

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'ServiceNotAllowedForPA',
        -mesg              => "Client is a PA",
        -message_to_client => localize('This service is not available for payment agents.'),
    ) unless $pa->service_is_allowed('trading');

    return undef;
}

sub _validate_offerings_buy {
    my ($self, $client) = @_;

    return $self->_validate_offerings($client, 'buy');
}

sub _validate_offerings_sell {
    my ($self, $client) = @_;

    return $self->_validate_offerings($client, 'sell');
}

sub _validate_offerings {
    my ($self, $client, $action) = @_;

    my $offerings_obj =
        $client->landing_company->basic_offerings_for_country($client->residence, BOM::Config::Runtime->instance->get_offerings_config($action));

    my $err = $offerings_obj->validate_offerings($self->transaction->contract->metadata($action));

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'InvalidOfferings',
        -mesg              => $err->{message},
        -message_to_client => localize(@{$err->{message_to_client}})) if $err;

    return undef;
}

sub _validate_currency {
    my ($self, $client) = (shift, shift);
    my $currency = $self->transaction->contract->currency;

    if (not $client->landing_company->is_currency_legal($currency)) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'InvalidCurrency',
            -mesg              => "Invalid $currency",
            -message_to_client => localize("The provided currency [_1] is invalid.", $currency),
        );
    }

    if ($client->default_account and $currency ne $client->currency) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NotDefaultCurrency',
            -mesg              => "not default currency for client [$currency], client currency[" . $client->currency . "]",
            -message_to_client => localize("The provided currency [_1] is not the default currency", $currency),
        );
    }

    return undef;
}

sub _validate_sell_pricing_adjustment {
    my $self = shift;

    my $transaction = $self->transaction;
    my $contract    = $transaction->contract;

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'BetExpired',
        -mesg              => 'Contract expired with a new price',
        -message_to_client => localize('The contract has expired'),
    ) if $contract->is_expired;

    # Due to the volatile nature of the bid price for multiplier (high multiplier),
    # all multiplier contracts will be closed at recomputed bid price without going through price movement checks.
    # This is specified in the contract terms and conditions.
    if (not defined $transaction->price or $contract->category_code eq 'multiplier') {
        $transaction->price($contract->bid_price);
        return undef;
    }

    return $self->_validate_binary_price_adjustment('bid_probability') if $contract->is_binary;
    return $self->_validate_non_binary_price_adjustment();
}

sub _validate_trade_pricing_adjustment {
    my $self = shift;

    return undef if $self->trade_adjusted;

    my $transaction = $self->transaction;
    my $contract    = $transaction->contract;

    return Error::Base->cuss(
        -type => 'BetExpired',
        -mesg => 'Bet expired with a new price[' . $transaction->recomputed_amount . '] (old price[' . $transaction->requestedamount . '])',
        -message_to_client => localize('The contract has expired'),
    ) if $contract->is_expired;

    if ($transaction->request_type eq 'payout') {
        # This is to avoid buying contract at exorbitant 'price' due to human error
        $transaction->price($contract->ask_price);
    }

    return $self->_validate_binary_price_adjustment('ask_probability') if $contract->is_binary;
    return $self->_validate_non_binary_price_adjustment();
}

sub _validate_binary_price_adjustment {
    my ($self, $probability_type) = @_;

    my $transaction = $self->transaction;
    my $contract    = $transaction->contract;
    my $move        = $transaction->get_price_move();
    my $multiplier  = $transaction->request_type eq 'price' ? $contract->payout : $transaction->payout;

    # $allowed_move is in payout currency amount.
    # $contract->min_commission_amount is in payout currency amount.
    my $allowed_move = max($contract->min_commission_amount * 0.5, $contract->allowed_slippage * $multiplier);

    $allowed_move = 0 if $contract->$probability_type->amount == 1;

    return $self->_adjust_trade($move, $allowed_move);
}

sub _validate_non_binary_price_adjustment {
    my $self = shift;

    # non_binary only deals in price space and not probability space.
    my $transaction  = $self->transaction;
    my $move         = $transaction->get_price_move();
    my $allowed_move = $transaction->contract->allowed_slippage;

    return $self->_adjust_trade($move, $allowed_move);
}

sub _adjust_trade {
    my ($self, $move, $allowed_move) = @_;

    $self->trade_adjusted(1);
    my $transaction = $self->transaction;
    # if we do not allow slippage
    if ($allowed_move == 0 and $move == 0) {
        $transaction->adjust_amount($transaction->recomputed_amount);
        return undef;
    }

    if ($move < -$allowed_move) {
        $transaction->record_slippage($move);

        if ($transaction->contract->category_code eq 'accumulator') {
            #for accumulator this case only happens if the client sells the contract right at the moment
            #contract expires (barrier violation). in this case, contract will be executed at zero payout
            #we don't need to reject the request, we just keep a record of this incident
            $transaction->adjust_amount($transaction->recomputed_amount);
            return undef;
        }

        return $self->_write_to_rejected({
            type              => 'slippage',
            action            => $self->transaction->action_type,
            amount            => $transaction->requested_amount,
            recomputed_amount => $transaction->recomputed_amount,
        });
    }

    if ($move <= $allowed_move and $move >= -$allowed_move) {
        # We absorbed the price difference here and we want to keep it in our book.
        $transaction->record_slippage($move);
        $transaction->adjust_amount($transaction->requested_amount);
    } elsif ($move > $allowed_move) {
        $transaction->execute_at_better_price(1);
        # We need to keep record of slippage even it is executed at better price
        $transaction->record_slippage($move);
        $transaction->adjust_amount($transaction->recomputed_amount);
    }

    return undef;
}

sub _slippage {
    my ($self, $p) = @_;

    my $what_changed = $p->{action} eq 'sell' ? 'sell price' : undef;
    $what_changed //= ($self->transaction->amount_type eq 'payout' or $self->transaction->amount_type eq 'multiplier') ? 'price' : 'payout';
    my ($market_moved, $contract) =
        (localize('The underlying market has moved too much since you priced the contract.'), $self->transaction->contract);
    my $currency = $contract->currency;
    $market_moved =
        $market_moved . ' '
        . localize(
        'The contract [_4] has changed from [_2] [_1] to [_3] [_1].',
        $currency,
        financialrounding('amount', $currency, $p->{amount}),
        financialrounding('amount', $currency, $p->{recomputed_amount}),
        $what_changed
        );

    #Record failed transaction here.
    for my $c ($self->clients->@*) {
        next unless $c->{client};
        my $rejected_trade = BOM::Database::Helper::RejectedTrade->new({
            login_id => $c->{client}->loginid,
            ($p->{action} eq 'sell') ? (financial_market_bet_id => $self->transaction->contract_id) : (),
            shortcode   => $contract->shortcode,
            action_type => $p->{action},
            reason      => 'SLIPPAGE',
            details     => $self->_get_rejected_contract_details('slippage'),
            db          => BOM::Database::ClientDB->new({broker_code => $c->{client}->broker_code})->db,
        });
        $rejected_trade->record_fail_txn();
    }
    return Error::Base->cuss(
        -quiet => 1,
        -type  => 'PriceMoved',
        -mesg  => "Difference between submitted and newly calculated bet price: currency "
            . $currency
            . ", amount: "
            . $p->{amount}
            . ", recomputed amount: "
            . $p->{recomputed_amount},
        -message_to_client => $market_moved,
    );
}

sub _get_rejected_contract_details {
    my ($self, $type) = @_;

    my $contract = $self->transaction->contract;
    my $details  = {
        current_tick_epoch => $contract->current_tick->epoch,
        pricing_epoch      => $contract->date_pricing->epoch,
        option_type        => $contract->code,
        currency_pair      => $contract->underlying->symbol,
        ($contract->two_barriers and $contract->low_barrier and $contract->high_barrier)
        ? (barriers => $contract->low_barrier->as_absolute . "," . $contract->high_barrier->as_absolute)
        : ($contract->can('barrier') && $contract->barrier) ? (barriers => $contract->barrier->as_absolute)
        : (barriers => ''),
        $contract->can('available_orders') ? (limit_order => $contract->available_orders)
        : (),
        expiry => $contract->date_expiry->db_timestamp,
        payout => $contract->payout,
    };

    if ($type eq 'slippage') {
        $details->{price_slippage}    = $self->transaction->price_slippage;
        $details->{requested_amount}  = $self->transaction->requested_amount;
        $details->{recomputed_amount} = $self->transaction->recomputed_amount;
    }
    my $details_json = $json->encode($details);

    return $details_json;
}

sub _invalid_contract {
    my ($self, $p) = @_;

    my $contract          = $self->transaction->contract;
    my $message_to_client = localize($contract->primary_validation_error->message_to_client);

    # invalid input can cause exception to be thrown hence, we just return the
    # validation error message to them without storing them into rejected trade table
    unless ($contract->invalid_user_input) {
        #Record failed transaction here.
        for my $c ($self->clients->@*) {
            next unless $c->{client};
            my $rejected_trade = BOM::Database::Helper::RejectedTrade->new({
                login_id => $c->{client}->loginid,
                ($p->{action} eq 'sell') ? (financial_market_bet_id => $self->transaction->contract_id) : (),
                shortcode   => $contract->shortcode,
                action_type => $p->{action},
                reason      => $message_to_client,
                details     => $self->_get_rejected_contract_details('invalid'),
                db          => BOM::Database::ClientDB->new({broker_code => $c->{client}->broker_code})->db,
            });
            $rejected_trade->record_fail_txn();
        }
    }

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => ($p->{action} eq 'buy' ? 'InvalidtoBuy' : 'InvalidtoSell'),
        -mesg              => $contract->primary_validation_error->message,
        -message_to_client => $message_to_client,
    );
}

sub _write_to_rejected {
    my ($self, $p) = @_;

    my $method = '_' . $p->{type};
    return $self->$method($p);
}

sub _is_valid_to_buy {
    my ($self, $client) = @_;

    my $contract = $self->transaction->contract;

    my $valid = $contract->is_valid_to_buy({
        landing_company => $client->landing_company->short,
        country_code    => $client->residence,
    });

    BOM::Transaction::Utility::report_validation_stats($contract, 'buy', $valid);

    unless ($valid) {
        return $self->_write_to_rejected({
            type   => 'invalid_contract',
            action => 'buy',
        });
    }

    return undef;
}

sub _is_valid_to_sell {
    my $self     = shift;
    my $contract = $self->transaction->contract;

    my $valid = $contract->is_valid_to_sell;

    BOM::Transaction::Utility::report_validation_stats($contract, 'sell', $valid);

    unless ($valid) {
        return $self->_write_to_rejected({
            type   => 'invalid_contract',
            action => 'sell',
        });
    }

    return undef;
}

sub _validate_date_pricing {
    my $self     = shift;
    my $contract = $self->transaction->contract;

    if (not $contract->is_expired
        and abs(time - $contract->date_pricing->epoch) > 20)
    {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'InvalidDatePricing',
            -mesg              => 'Bet was validated for a time [' . $contract->date_pricing->epoch . '] too far from now[' . time . ']',
            -message_to_client => localize('This contract cannot be properly validated at this time.'));
    }
    return undef;
}

# This validation should always come after _validate_trade_pricing_adjustment
# because we recompute the price and that's the price that we going to transact with!
sub _validate_stake_limit {
    my $self     = shift;
    my $client   = shift;
    my $contract = $self->transaction->contract;
    my $currency = $contract->currency;

    if ($contract->is_binary) {
        my $landing_company = $client->landing_company;
        my $stake_limit     = $contract->staking_limits->{min};    # minimum is always a stake check

        if ($contract->ask_price < $stake_limit) {
            return Error::Base->cuss(
                -quiet => 1,
                -type  => 'StakeTooLow',
                -mesg  => $client->loginid . ' stake [' . $contract->ask_price . '] is lower than minimum allowable stake [' . $stake_limit . ']',
                -message_to_client => localize(
                    "This contract's price is [_2] [_1]. Contracts purchased from [_3] must have a purchase price above [_4] [_1]. Please accordingly increase the contract amount to meet this minimum stake.",
                    $currency,
                    financialrounding('price', $currency, $contract->ask_price),
                    $landing_company->name,
                    financialrounding('amount', $currency, $stake_limit)
                ),
            );
        }
    } else {
        my $max_stake_per_trade = $self->transaction->limits->{max_stake_per_trade} // undef;

        return undef unless defined($max_stake_per_trade);

        if ($contract->ask_price > $max_stake_per_trade) {
            return Error::Base->cuss(
                -type              => 'StakeLimitExceeded',
                -mesg              => 'Stake Limit Exceeded',
                -message_to_client => localize("Maximum stake allowed is [_1].", financialrounding('amount', $currency, $max_stake_per_trade)),
            );
        }

    }

    return undef;
}

sub _validate_no_volume_limit {
    my ($self, $client) = (shift, shift);
    my $volume = $self->transaction->limits->{volume};

    return undef if !defined $volume;

    if (defined $volume->{per_user} && $volume->{per_user} == 0) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NoBusiness',
            -mesg              => $client->loginid . ' manually disabled by quants',
            -message_to_client => localize('This contract is unavailable on this account.'),
        );
    }

    if (defined $volume->{per_user_symbol} && $volume->{per_user_symbol} == 0) {
        my $display_name = $self->transaction->contract->underlying->display_name;
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NoBusiness',
            -mesg              => "multiplier options on $display_name manually disabled by quants",
            -message_to_client => localize("Trading multiplier options on [_1] is disabled. Please choose another market.", $display_name,),
        );
    }
    return undef;
}

=head2 $self->_validate_payout_limit

Validate if payout is not over the client limits

=cut

sub _validate_payout_limit {
    my ($self, $client) = (shift, shift);

    my $contract = $self->transaction->contract;
    return undef unless $contract->is_binary;

    my $rp    = $contract->risk_profile;
    my @cl_rp = $rp->get_client_profiles($client->loginid, $client->landing_company->short);

    # setups client specific payout and turnover limits, if any.
    if (@cl_rp) {
        my $custom_profile = $rp->get_risk_profile(\@cl_rp);
        if ($custom_profile eq 'no_business') {
            return Error::Base->cuss(
                -quiet             => 1,
                -type              => 'NoBusiness',
                -mesg              => $client->loginid . ' manually disabled by quants',
                -message_to_client => localize('This contract is unavailable on this account.'),
            );
        }

        my $custom_limit =
            get_exchangerates_limit(BOM::Config::quants()->{risk_profile}{$custom_profile}{payout}{$contract->currency}, $contract->currency);
        if (defined $custom_limit and (my $payout = $self->transaction->payout) > $custom_limit) {
            return Error::Base->cuss(
                -quiet             => 1,
                -type              => 'PayoutLimitExceeded',
                -mesg              => $client->loginid . ' payout [' . $payout . '] over custom limit[' . $custom_limit . ']',
                -message_to_client => ($custom_limit == 0)
                ? localize('This contract is unavailable on this account.')
                : localize(
                    'This contract is limited to [_1] payout on this account.',
                    financialrounding('amount', $contract->currency, $custom_limit)
                ),
            );
        }
    }

    return undef;
}

=head2 $self->_validate_jurisdictional_restrictions

Validates whether the client has provided his residence country

=cut

sub _validate_jurisdictional_restrictions {
    my ($self, $client) = (shift, shift);

    my $contract = $self->transaction->contract;

    my $residence   = $client->residence;
    my $market_name = $contract->market->name;

    if (not $residence and not $client->is_virtual) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NoResidenceCountry',
            -mesg              => 'Client cannot place contract as we do not know their residence.',
            -message_to_client =>
                localize('In order for you to place contracts, we need to know your Residence (Country). Please update your settings.'),
        );
    }

    my $lc = $client->landing_company;

    my %legal_allowed_cc = map { $_ => 1 } @{$lc->legal_allowed_contract_categories};
    if (not $legal_allowed_cc{$contract->category_code}) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NotLegalContractCategory',
            -mesg              => 'Clients are not allowed to trade on this contract category as its restricted for this landing company',
            -message_to_client => localize('Please switch accounts to trade this contract.'),
        );
    }

    if (not grep { $market_name eq $_ } @{$lc->legal_allowed_markets}) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NotLegalMarket',
            -mesg              => 'Clients are not allowed to trade on this markets as its restricted for this landing company',
            -message_to_client => localize('Please switch accounts to trade this market.'),
        );
    }

    return undef;
}

=head2 $self->_validate_client_status

Validates to make sure that the client with unwelcome status
is not able to purchase contract.

=cut

sub _validate_client_status {
    my ($self, $client) = (shift, shift);

    my $status = $client->status;

    if ($status->unwelcome or $status->disabled or $status->no_trading or $status->no_withdrawal_or_trading) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'ClientUnwelcome',
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize('Sorry, your account is not authorised for any further contract purchases.'),
        );
    }

    return undef;
}

=head2 $self->_validate_client_self_exclusion

Validates to make sure that the client with self exclusion
is not able to purchase contract

=cut

sub _validate_client_self_exclusion {
    my ($self, $client) = (shift, shift);

    if (my $limit_excludeuntil = $client->get_self_exclusion_until_date) {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'ClientSelfExcluded',
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize(
                'You have chosen to exclude yourself from trading on our website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact us via live chat.',
                $limit_excludeuntil
            ),
        );
    }

    return undef;
}

################ Client only validation ########################

sub validate_tnc {
    my ($self, $client) = (shift, shift);

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'ASK_TNC_APPROVAL',
        -mesg              => 'Terms and conditions approval is required',
        -message_to_client => localize('Terms and conditions approval is required.'),
    ) if $client->is_tnc_approval_required;

    return undef;
}

sub compliance_checks {
    my ($self, $client) = (shift, shift);

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'FinancialAssessmentRequired',
        -mesg              => 'Please complete the financial assessment form to lift your withdrawal and trading limits.',
        -message_to_client => localize('Please complete the financial assessment form to lift your withdrawal and trading limits.'),
    ) unless $client->is_financial_assessment_complete();

    return undef;
}

sub check_tax_information {
    my ($self, $client) = (shift, shift);

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'TINDetailsMandatory',
        -mesg              => 'Tax-related information is mandatory for legal and regulatory requirements',
        -message_to_client =>
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')
    ) unless $client->status->crs_tin_information;

    return undef;
}

=head2 check_client_can_trade

Checks if client can trade:
- Client with unwelcome status cannot buy but can sell.
- Client with disabled, no_trading and no_withdrawal_or_trading status cannot buy & sell.

=cut

sub check_client_can_trade {
    my ($self, $client) = @_;

    my $status = $client->status;

    # for unwelcome clients, we want to allow them to sell contracts.
    if (   ($self->transaction->action_type eq 'buy' and $status->unwelcome)
        or $status->disabled
        or $status->no_trading
        or $status->no_withdrawal_or_trading)
    {
        my $type =
              $status->unwelcome  ? 'ClientUnwelcome'
            : $status->disabled   ? 'ClientDisabled'
            : $status->no_trading ? 'ClientNoTrading'
            :                       'ClientNoWithdrawalNoTrading';
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => $type,
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize('Sorry, your account is not authorised for any further contract purchases.'),
        );
    }
}

=head2 check_authentication_required

Check if client is age verified for

- MF without confirmed age after the first deposit
- MF without fully_authentication

=cut

sub check_authentication_required {
    my ($self, $client) = (shift, shift);

    if (   ($client->has_deposits and not $client->status->age_verification)
        or ($client->landing_company->short eq 'maltainvest' and not $client->fully_authenticated))
    {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'PleaseAuthenticate',
            -mesg              => 'Please authenticate your account to continue',
            -message_to_client => localize('Please authenticate your account to continue.'),
        );
    }

    return undef;
}

=head2 check_client_professional

Check if client is professional for maltainvest landing company

=cut

sub check_client_professional {
    my ($self, $client) = (shift, shift);

    return undef unless ($client->landing_company->short eq 'maltainvest');
    return undef unless $self->transaction->contract->is_binary;

    return Error::Base->cuss(
        -quiet             => 1,
        -type              => 'NoMFProfessionalClient',
        -mesg              => 'your account is not authorised for any further contract purchases.',
        -message_to_client => localize('Sorry, your account is not authorised for any further contract purchases.'),
    ) unless $client->status->professional;

    return undef;
}

=head2 synthetic_age_verification_check

If client residence has require_age_verified_for_synthetic flag,
they must be age verified to buy synthetic contracts.

=cut

sub synthetic_age_verification_check {
    my ($self, $client) = (shift, shift);

    return undef if $self->transaction->contract->market->name ne 'synthetic_index';

    if (request()->brand->countries_instance->countries_list->{$client->residence}{require_age_verified_for_synthetic}
        and not $client->status->age_verification)
    {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NeedAuthenticateForSynthetic',
            -mesg              => 'Please authenticate your account to trade on synthetic markets.',
            -message_to_client => localize('Please authenticate your account to trade on synthetic markets.'));
    }

    return undef;
}

1;
