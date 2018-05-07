package BOM::Transaction::Validation;

use strict;
use warnings;

use Moo;
use Error::Base;
use List::Util qw(min max first any);
use YAML::XS qw(LoadFile);
use JSON::MaybeXS;

use Format::Util::Numbers qw/formatnumber/;
use Postgres::FeedDB::CurrencyConverter qw(amount_from_to_currency);
use BOM::Database::Helper::RejectedTrade;
use BOM::Platform::Context qw(localize request);
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use Locale::Country::Extra;
use Geo::Region;
use Geo::Region::Constant qw( :all );
use BOM::Database::ClientDB;
use Date::Utility;

has clients => (
    is       => 'ro',
    required => 1
);

has transaction => (is => 'ro');

my $json = JSON::MaybeXS->new;
################ Client and transaction validation ########################

sub validate_trx_sell {
    my $self = shift;
    ### Client-depended checks
    my $clients;
    $clients = $self->transaction->multiple if $self->transaction;
    $clients = [map { +{client => $_} } @{$self->clients}] unless $clients;

    my @client_validation_method =
        qw/ check_trade_status _validate_available_currency _validate_currency _validate_iom_withdrawal_limit _validate_offerings_sell /;

    my @contract_validation_method = qw/_is_valid_to_sell _validate_sell_pricing_adjustment _validate_date_pricing/;

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};
        foreach my $method (@client_validation_method) {
            my $res = $self->$method($c->{client});
            next unless $res;
            if ($self->transaction && $self->transaction->multiple) {
                $c->{code}  = $res->get_type;
                $c->{error} = $res->{-message_to_client};
                next CLI;
            }
            return $res;
        }
    }

    foreach my $c_method (@contract_validation_method) {
        my $res = $self->$c_method();

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
    my $clients;
    $clients = $self->transaction->multiple if $self->transaction;
    $clients = [map { +{client => $_} } @{$self->clients}] unless $clients;

    # If contract has 'primary_validation_error'(which is checked inside)
    # we should not do any other checks and should return an error.
    # additionally this check will be done inside _is_valid_to_buy check, but we will not return an error from there
    $res = $self->_is_valid_to_buy($self->transaction->client);
    return $res if $res;

    my @client_validation_method = qw/ check_trade_status
        _validate_client_status
        _validate_available_currency
        _validate_currency
        validate_tnc
        _validate_iom_withdrawal_limit
        _validate_jurisdictional_restrictions
        _validate_client_self_exclusion
        _validate_offerings_buy
        _is_valid_to_buy/;    # do _is_valid_to_buy as last of the validation

    CLI: for my $c (@$clients) {
        next CLI if !$c->{client} || $c->{code};
        foreach my $method (@client_validation_method) {
            $res = $self->$method($c->{client});
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
            next unless $self->transaction->contract->is_binary;
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

    my $method = $self->transaction->contract->is_parameters_predefined ? 'multi_barrier_offerings_for_country' : 'basic_offerings_for_country';
    my $offerings_obj = $client->landing_company->$method($client->residence, BOM::Platform::Runtime->instance->get_offerings_config);

    my $err = $offerings_obj->validate_offerings($self->transaction->contract->metadata($action));

    return Error::Base->cuss(
        -type              => 'InvalidOfferings',
        -mesg              => $err->{message},
        -message_to_client => localize(@{$err->{message_to_client}})) if $err;

    return;
}

sub _validate_available_currency {
    my ($self, $client) = (shift, shift);

    my $currency = $self->transaction->contract->currency;
    return Error::Base->cuss(
        -type              => 'InvalidCurrency',
        -mesg              => "Invalid $currency",
        -message_to_client => localize("The provided currency [_1] is invalid.", $currency),
    ) unless $client->landing_company->is_currency_legal($currency);

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

    if (not $client->landing_company->is_currency_legal($currency)) {
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

    my $requested = $contract->is_binary ? $self->transaction->price / $self->transaction->payout : $self->transaction->price;
    my ($amount, $recomputed_amount) = ($self->transaction->price, $contract->bid_price);
    # set the requested price and recomputed  price to be store in db
    ### TODO: move out from validation
    $self->transaction->requested_price($amount);
    $self->transaction->recomputed_price($recomputed_amount);
    my $recomputed      = $contract->is_binary ? $contract->bid_probability->amount : $contract->bid_price;
    my $non_binary_move = ($requested == 0)    ? $recomputed - $requested           : ($recomputed - $requested) / $requested;
    my $move            = $contract->is_binary ? $recomputed - $requested           : $non_binary_move;
    my $slippage        = $recomputed_amount - $amount;
    my $allowed_move    = $contract->allowed_slippage;

    $allowed_move = 0 if $contract->is_binary and $recomputed == 1;

    return if $move == 0;

    my $final_value;
    if ($allowed_move == 0 or $slippage == 0) {
        $final_value = $recomputed_amount;
    } elsif ($move < -$allowed_move) {
        return $self->_write_to_rejected({
            type              => 'slippage',
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

    my $requested = $contract->is_binary ? $self->transaction->price / $self->transaction->payout : $self->transaction->price;
    # set the requested price and recomputed price to be store in db
    $self->transaction->requested_price($self->transaction->price);
    $self->transaction->recomputed_price($contract->ask_price);
    my $recomputed = $contract->is_binary ? $contract->ask_probability->amount : $contract->ask_price;
    my $move       = $contract->is_binary ? $requested - $recomputed           : ($requested - $recomputed) / $requested;
    my $slippage   = $self->transaction->price - $contract->ask_price;
    my $allowed_move = $contract->allowed_slippage;

    $allowed_move = 0 if $contract->is_binary and $recomputed == 1;

    # non-binary where $amount_type is multiplier always work in price space.
    my ($amount, $recomputed_amount) = (
               $amount_type eq 'payout'
            or $amount_type eq 'multiplier'
    ) ? ($self->transaction->price, $contract->ask_price) : ($self->transaction->payout, $contract->payout);

    return if $move == 0;

    my $final_value;

    return Error::Base->cuss(
        -type              => 'BetExpired',
        -mesg              => 'Bet expired with a new price[' . $recomputed_amount . '] (old price[' . $amount . '])',
        -message_to_client => localize('The contract has expired'),
    ) if $contract->is_expired;

    if ($allowed_move == 0 or $slippage == 0) {
        $final_value = $recomputed_amount;
    } elsif ($move < -$allowed_move) {
        return $self->_write_to_rejected({
            type              => 'slippage',
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

    # For non-binary where $amount_type is always equals to multiplier.
    # We will non need to consider the case where it is 'payout'.
    if ($amount_type eq 'payout' or $amount_type eq 'multiplier') {
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

sub _slippage {
    my ($self, $p) = @_;

    my $what_changed = $p->{action} eq 'sell' ? 'sell price' : undef;
    $what_changed //= ($self->transaction->amount_type eq 'payout' or $self->transaction->amount_type eq 'multiplier') ? 'price' : 'payout';
    my ($market_moved, $contract) =
        (localize('The underlying market has moved too much since you priced the contract. '), $self->transaction->contract);
    my $currency = $contract->currency;
    $market_moved .= localize(
        'The contract [_4] has changed from [_1][_2] to [_1][_3].',
        $currency,
        formatnumber('amount', $currency, $p->{amount}),
        formatnumber('amount', $currency, $p->{recomputed_amount}),
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
                details     => $json->encode({
                        order_price      => $self->transaction->price,
                        recomputed_price => $p->{action} eq 'buy' ? $contract->ask_price : $contract->bid_price,
                        slippage         => $self->transaction->price - $contract->ask_price,
                        option_type      => $contract->code,
                        currency_pair    => $contract->underlying->symbol,
                        ($self->transaction->trading_period_start) ? (trading_period_start => $self->transaction->trading_period_start->db_timestamp)
                        : (),
                        ($contract->two_barriers) ? (barriers => $contract->low_barrier->as_absolute . "," . $contract->high_barrier->as_absolute)
                        : $contract->barrier      ? (barriers => $contract->barrier->as_absolute)
                        : (),
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
            . $currency
            . ", amount: "
            . $p->{amount}
            . ", recomputed amount: "
            . $p->{recomputed_amount},
        -message_to_client => $market_moved,
    );
}

sub _invalid_contract {
    my ($self, $p) = @_;

    my $contract          = $self->transaction->contract;
    my $message_to_client = localize($contract->primary_validation_error->message_to_client);
    #Record failed transaction here.
    for my $c (@{$self->clients}) {
        my $rejected_trade = BOM::Database::Helper::RejectedTrade->new({
                login_id => $c->loginid,
                ($p->{action} eq 'sell') ? (financial_market_bet_id => $self->transaction->contract_id) : (),
                shortcode   => $contract->shortcode,
                action_type => $p->{action},
                reason      => $message_to_client,
                details     => $json->encode({
                        current_tick_epoch => $contract->current_tick->epoch,
                        pricing_epoch      => $contract->date_pricing->epoch,
                        option_type        => $contract->code,
                        currency_pair      => $contract->underlying->symbol,
                        ($self->transaction->trading_period_start) ? (trading_period_start => $self->transaction->trading_period_start->db_timestamp)
                        : (),
                        ($contract->two_barriers) ? (barriers => $contract->low_barrier->as_absolute . "," . $contract->high_barrier->as_absolute)
                        : ($contract->barrier)    ? (barriers => $contract->barrier->as_absolute)
                        : (barriers => ''),
                        expiry => $contract->date_expiry->db_timestamp,
                        payout => $contract->payout
                    }
                ),
                db => BOM::Database::ClientDB->new({broker_code => $c->broker_code})->db,
            });
        $rejected_trade->record_fail_txn();
    }

    return Error::Base->cuss(
        -type => ($p->{action} eq 'buy' ? 'InvalidtoBuy' : 'InvalidtoSell'),
        -mesg => $contract->primary_validation_error->message,
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

    unless ($contract->is_valid_to_buy({landing_company => $client->landing_company->short})) {
        return $self->_write_to_rejected({
            type   => 'invalid_contract',
            action => 'buy',
        });
    }

    return;
}

sub _is_valid_to_sell {
    my $self     = shift;
    my $contract = $self->transaction->contract;

    unless ($contract->is_valid_to_sell) {
        return $self->_write_to_rejected({
            type   => 'invalid_contract',
            action => 'sell',
        });
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

    my $landing_company_short = $client->landing_company->short;
    return if ($landing_company_short ne 'iom');

    my $payment_limits = BOM::User::Client::payment_limits();

    my $withdrawal_limits = $payment_limits->{withdrawal_limits};
    my $numdays           = $withdrawal_limits->{$landing_company_short}->{for_days};
    my $numdayslimit      = $withdrawal_limits->{$landing_company_short}->{limit_for_days};
    my $lifetimelimit     = $withdrawal_limits->{$landing_company_short}->{lifetime_limit};

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
    $withdrawal_in_days = formatnumber('amount', 'EUR', amount_from_to_currency($withdrawal_in_days, $client->currency, 'EUR'));

    # withdrawal since inception
    my $withdrawal_since_inception = $payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']});
    $withdrawal_since_inception = formatnumber('amount', 'EUR', amount_from_to_currency($withdrawal_since_inception, $client->currency, 'EUR'));

    my $remaining_withdrawal_eur =
        formatnumber('amount', 'EUR', min(($numdayslimit - $withdrawal_in_days), ($lifetimelimit - $withdrawal_since_inception)));

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
                formatnumber('price', $currency, $contract->ask_price),
                $landing_company->name,
                formatnumber('amount', $currency, $stake_limit)
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
                : localize(
                    'This contract is limited to ' . formatnumber('amount', $contract->currency, $custom_limit) . ' payout on this account.'
                ),
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

    my $contract = $self->transaction->contract;

    my $residence   = $client->residence;
    my $market_name = $contract->market->name;

    if (not $residence and not $client->is_virtual) {
        return Error::Base->cuss(
            -type => 'NoResidenceCountry',
            -mesg => 'Client cannot place contract as we do not know their residence.',
            -message_to_client =>
                localize('In order for you to place contracts, we need to know your Residence (Country). Please update your settings.'),
        );
    }

    my $lc = $client->landing_company;

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

    if (my $limit_excludeuntil = $client->get_self_exclusion_until_date) {
        return Error::Base->cuss(
            -type              => 'ClientSelfExcluded',
            -mesg              => 'your account is not authorised for any further contract purchases.',
            -message_to_client => localize(
                'Sorry, but you have self-excluded yourself from the website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact the Customer Support team for assistance.',
                $limit_excludeuntil
            ),
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

=head2 check_trade_status

Check if client is allowed to trade.

Here we have any uncommon business logic check.

Common checks (unwelcome & disabled) are done _validate_client_status.

Don't allow to trade for:
- MLT, MX and MF without confirmed age
- MF without fully_authentication

=cut

sub check_trade_status {
    my ($self, $client) = (shift, shift);

    return if $client->is_virtual;

    if ((
                ($client->landing_company->short =~ /^(?:maltainvest|malta|iom)$/)
            and not $client->get_status('age_verification')
            and $client->has_deposits
        )
        or ($client->landing_company->short eq 'maltainvest' and not $client->client_fully_authenticated))
    {
        return Error::Base->cuss(
            -type              => 'PleaseAuthenticate',
            -mesg              => 'Please authenticate your account to continue',
            -message_to_client => localize('Please authenticate your account to continue.'),
        );
    }
    return;
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

1;
