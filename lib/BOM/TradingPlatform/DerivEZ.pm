package BOM::TradingPlatform::DerivEZ;

use strict;
use warnings;
no indirect;

use BOM::Rules::Engine;
use BOM::MT5::User::Async;
use Syntax::Keyword::Try;
use Format::Util::Numbers qw(formatnumber);
use Log::Any              qw($log);
use BOM::Platform::Event::Emitter;
use BOM::User::Client;
use LandingCompany::Registry;
use BOM::TradingPlatform::Helper::HelperDerivEZ qw(
    new_account_trading_rights
    create_error
    validate_new_account_params
    validate_user
    generate_password
    is_account_demo
    is_restricted_group
    derivez_group
    do_derivez_deposit
    get_derivez_account_type_config
    derivez_accounts_lookup
    payment_agent_trading_rights
    affiliate_trading_rights
    is_identical_group
    get_landing_company
    derivez_validate_and_get_amount
    record_derivez_transfer_to_mt5_transfer
    send_transaction_email
    do_derivez_withdrawal
    get_derivez_landing_company
);

use constant MT5_SVG_FINANCIAL_MOCK_LEVERAGE => 1;
use constant MT5_SVG_FINANCIAL_REAL_LEVERAGE => 1000;

use parent qw(BOM::TradingPlatform);

=head1 NAME 

BOM::TradingPlatform::DerivEZ

=head1 SYNOPSIS 

    my $platform = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

=head1 DESCRIPTION 

Provides a high level implementation of the DerivEZ API with MetaTrader5 as the BE server.

Exposes DerivEZ API through our trading platform interface.

=cut

=head2 new

Creates and returns a new L<BOM::TradingPlatform::DerivEZ> instance.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        client      => $args{client},
        rule_engine => $args{rule_engine}}, $class;
}

=head2 new_account

    my $args = {
        account_type => $account_type,
        market_type => $market_type,
        platform => $platform,
        dry_run => $dry_run,
        currency => $currency
    }

    my $platform = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    my $account = $platform->new_account($args);

=cut

sub new_account {
    my ($self, %args) = @_;

    # We need to validate the params from FE
    my $validate_new_account_params = validate_new_account_params(%args);
    return create_error($validate_new_account_params) if $validate_new_account_params;

    # Params/args from FE
    my $account_type          = delete $args{account_type};
    my $market_type           = delete $args{market_type};
    my $platform              = delete $args{platform};
    my $currency              = delete $args{currency};
    my $dry_run               = delete $args{dry_run};
    my $landing_company_short = delete $args{company};

    # Build client and user object
    my $client = $self->client;
    my $user   = $client->user;

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    try {
        $rule_engine->verify_action(
            'new_mt5_dez_account',
            loginid      => $client->loginid,
            account_type => $account_type
        );
    } catch ($error) {
        return create_error($error->{error_code}, {params => 'DerivEZ'});
    }

    # Build client params if missing
    unless ($landing_company_short) {
        try {
            $landing_company_short = $client->landing_company->short;
        } catch {
            if (not defined $landing_company_short) {
                $landing_company_short = get_derivez_landing_company($client);
                return create_error($landing_company_short->{error}, {params => $client->residence}) if $landing_company_short->{error};
            }
        }
    }

    # Validate if the client's country support derivez account creation
    my $all_company_landing_company = get_derivez_landing_company($client);
    unless ($all_company_landing_company) {
        return create_error('DerivezNotAllowed');
    }

    # Validate if currency is provided as params
    my $default_currency   = LandingCompany::Registry->by_name($landing_company_short)->get_default_currency($client->residence);
    my $available          = $client->landing_company->available_mt5_currency_group();
    my %available_currency = map { $_ => 1 } @$available;
    my $selected_currency =
          ($account_type ne 'demo' && $available_currency{$client->currency}) ? $client->currency
        : $available_currency{$default_currency}                              ? $default_currency
        :                                                                       $available->[0];
    my $account_currency = $currency // $selected_currency;
    return create_error('permission') if $account_currency ne $selected_currency;

    # Innitialize params
    my $client_info         = $client->get_mt5_details();
    my $main_password       = generate_password($client->user->{password});
    my $investor_password   = generate_password($client->user->{password});
    my $rights              = new_account_trading_rights();
    my $binary_company_name = get_landing_company($client);
    my $group               = derivez_group({
        residence             => $client->residence,
        landing_company_short => $landing_company_short,
        account_type          => $account_type,
        currency              => $account_currency,
    });

    # Add a switch to a qualified accounts
    if ($account_type ne 'demo' and $client->landing_company->short ne $binary_company_name) {
        my @clients = $user->clients_for_landing_company($binary_company_name);
        # remove disabled/duplicate accounts to make sure that atleast one Real account is active
        @clients = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
        $client  = (@clients > 0) ? $clients[0] : undef;
    }

    # Check if a real mt5 accounts was being created with no real binary account existing
    return create_error_future('RealAccountMissing')
        if ($account_type ne 'demo' and scalar($user->clients) == 1 and $client->is_virtual());

    # Disable trading for affiliate accounts
    $rights = affiliate_trading_rights() if $client->landing_company->is_for_affiliates;

    # Disable trading for payment agents
    $rights = payment_agent_trading_rights() if (defined $client->payment_agent && $client->payment_agent->status eq 'authorized');

    # Get the group settings
    my $group_setting = BOM::MT5::User::Async::get_group($group)->catch(
        sub {
            my $err = shift;

            return create_error($err->{code}, {message => $err->{error}}) if (ref $err eq 'HASH' and $err->{code});
            return $err;
        })->get;
    return $group_setting if $group_setting->{error};

    $group_setting->{leverage} = MT5_SVG_FINANCIAL_REAL_LEVERAGE if $group_setting->{leverage} == MT5_SVG_FINANCIAL_MOCK_LEVERAGE;

    # Build all the params
    my $new_account_params = {
        platform              => $platform,
        city                  => $client_info->{city},
        email                 => $client_info->{email},
        restricted_group      => is_restricted_group($client->residence),
        leverage              => $group_setting->{leverage},
        phone                 => $client_info->{phone},
        currency              => $account_currency,
        investPassword        => $investor_password,
        state                 => $client_info->{state},
        landing_company_short => $landing_company_short,
        zipCode               => $client_info->{zipCode},
        rights                => $rights,
        name                  => $client_info->{name},
        mainPassword          => $main_password,
        country               => $client_info->{country},
        group                 => $group,
        address               => $client_info->{address},
        account_type          => $account_type,
        market_type           => $market_type
    };

    # Before we create new derivez user we need to validate the user and params
    my $validate_user = validate_user($client, $new_account_params,);
    return $validate_user if $validate_user->{error};

    # This is for dry run mode
    return {
        account_type    => $account_type,
        balance         => 0,
        currency        => 'USD',
        display_balance => '0.00'
    } if $dry_run;

    # We need to make sure the client dont have multiple account in one trade server
    my $accounts = derivez_accounts_lookup($client, $account_type)->then(
        sub {
            my (@logins) = @_;

            my (%existing_groups, $trade_server_error, $has_hr_account);
            foreach my $derivez_account (@logins) {
                if ($derivez_account->{error} and $derivez_account->{error}{code} eq 'MT5AccountInaccessible') {
                    $trade_server_error = $derivez_account->{error};
                    last;
                }

                $existing_groups{$derivez_account->{group}} = $derivez_account->{login} if $derivez_account->{group};

                $has_hr_account = 1 if lc($derivez_account->{group}) =~ /synthetic/ and lc($derivez_account->{group}) =~ /(\-hr|highrisk)/;
            }

            if ($trade_server_error) {
                return create_error(
                    'MT5AccountCreationSuspended',
                    {
                        override_code => 'MT5CreateUserError',
                        message       => $trade_server_error->{message_to_client},
                    });
            }

            # If one of client's account has been moved to high-risk groups
            # client shouldn't be able to open a non high-risk account anymore
            # so, here we set convert the group to high-risk version of the selected group if applicable
            if ($has_hr_account and $account_type ne 'demo' and $group =~ /synthetic/ and not $group =~ /\-/) {
                my ($division) = $group =~ /\\[a-zA-Z]+_([a-zA-Z]+)_/;
                my $new_group = $group =~ s/$division/$division-hr/r;

                # We don't have counter for svg hr groups.
                # Remove it from group name if the original has it
                $new_group =~ s/\\\d+$//;

                if (get_derivez_account_type_config($new_group)) {
                    $group = $new_group;
                } else {
                    $log->warnf("Unable to find high risk group %s for client %s with original group of %s.", $new_group, $client->loginid, $group);

                    return create_error('MT5CreateUserError');
                }
            }

            # Can't create account on the same group
            if (my $identical = is_identical_group($group, \%existing_groups)) {
                return create_error(
                    'MT5Duplicate',
                    {
                        override_code => 'MT5CreateUserError',
                        params        => [$account_type, $existing_groups{$identical}]});
            }
        }
    )->catch(
        sub {
            my $err = shift;

            if (ref $err eq 'HASH' and $err->{code}) {
                return create_error($err->{code}, {message => $err->{error}});
            } else {
                return $err;
            }
        })->get;
    return $accounts if $accounts->{error};

    # Create derivez account for user
    return BOM::MT5::User::Async::create_user($new_account_params)->then(
        sub {
            my ($status) = shift;

            if ($status->{error}) {
                return create_error('permission') if $status->{error} =~ /Not enough permissions/;
                return create_error('MT5CreateUserError', {message => $status->{error}});
            }

            my $derivez_login = $status->{login};
            my ($derivez_currency, $derivez_leverage) = @{$new_account_params}{qw/currency leverage/};
            my $account_type = is_account_demo($new_account_params->{group}) ? 'demo' : 'real';

            my $derivez_attributes = {
                group           => $group,
                landing_company => $binary_company_name,
                currency        => $derivez_currency,
                market_type     => $market_type,
                account_type    => $account_type,
                leverage        => $derivez_leverage
            };

            $user->add_loginid($derivez_login, 'derivez', $account_type, $derivez_currency, $derivez_attributes);

            # This is for linking new client to affiliate
            my $group_config = get_derivez_account_type_config($group);
            return create_error('permission') unless $group_config;

            if ($client->myaffiliates_token and $account_type ne 'demo') {
                BOM::Platform::Event::Emitter::emit(
                    'link_myaff_token_to_mt5',
                    {
                        client_loginid     => $client->loginid,
                        client_mt5_login   => $derivez_login,
                        myaffiliates_token => $client->myaffiliates_token,
                        server             => $group_config->{server}});
            }

            # funds in Virtual money
            my $balance = 0;
            if ($account_type eq 'demo') {
                $balance = 10000;
                do_derivez_deposit($derivez_login, $balance, 'DerivEZ Virtual Money deposit');
            }

            return {
                login                 => $derivez_login,
                balance               => $balance,
                display_balance       => formatnumber('amount', $new_account_params->{currency}, $balance),
                currency              => $new_account_params->{currency},
                account_type          => $account_type,
                agent                 => $new_account_params->{agent},
                market_type           => $market_type,
                landing_company_short => $landing_company_short,
                platform              => 'derivez',
            };
        })->get;
}

=head2 get_accounts

    my $platform = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    my $account = $platform->get_accounts;

=cut

sub get_accounts {
    my ($self, %args) = @_;
    my $account_type = $args{type};

    return derivez_accounts_lookup($self->client, $account_type)->then(
        sub {
            my (@logins) = @_;
            my @valid_logins = grep { defined $_ and $_ } @logins;

            return Future->done(\@valid_logins);
        })->get;
}

=head2 deposit

    my $args = {
        platform => $platform,
        from_account => $from_deriv_account,
        to_account => $to_derivez_account,
        amount => $amount,
        currency => $currency
    }

    my $platform = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    my $account = $platform->deposit($args);

=cut

sub deposit {
    my ($self, %args) = @_;

    # Params/args from FE
    my $fm_loginid = delete $args{from_account};
    my $to_derivez = delete $args{to_account};
    my $amount     = delete $args{amount};

    # Optional Params
    my $source                 = delete $args{source};
    my $return_derivez_details = delete $args{return_derivez_details};

    # Build client and user object
    my $client = $self->client;

    return create_error('Experimental')
        if BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $client->currency);

    my $error_code = 'DerivEZDepositError';
    my $response   = derivez_validate_and_get_amount($client, $fm_loginid, $to_derivez, $amount, $error_code);
    return $response if $response->{error};

    my $account_type;
    if ($response->{top_up_virtual}) {

        my $amount_to_topup = 10000;

        my $top_up_virtual_status = do_derivez_deposit($to_derivez, $amount_to_topup, 'DerivEZ Virtual Money deposit');
        if ($top_up_virtual_status->{error}) {
            return create_error($top_up_virtual_status->{code}) if $top_up_virtual_status->{error};
        } else {
            return {status => 1};
        }
    } else {
        # This status is intended to block withdrawals from binary to MT5
        # For DerivEZ we are still using mt5 as the BE trade server
        return create_error('WithdrawalLocked', {override_code => $error_code}) if $client->status->mt5_withdrawal_locked;

        $account_type = $response->{account_type};
    }
    my $fm_client = BOM::User::Client->get_client_instance($fm_loginid, 'write');
    my $balance   = $fm_client->default_account->balance;

    # Checks if balance is exceeded
    return create_error(
        $error_code,
        {
            message => localize("The maximum amount you may transfer is: [_1].", $balance),
        }) if $balance > 0 and $amount > $balance;

    # From the point of view of our system, we're withdrawing
    # money to deposit into MT5
    unless ($fm_client->is_virtual) {

        my $rule_engine = BOM::Rules::Engine->new(client => $fm_client);

        try {
            $fm_client->validate_payment(
                currency     => $fm_client->default_account->currency_code(),
                amount       => -1 * $amount,
                payment_type => 'mt5_transfer',
                rule_engine  => $rule_engine,
            );
        } catch ($e) {
            return create_error(
                $error_code,
                {
                    message => $e->{message_to_client},
                });
        };
    }

    my $fees                  = $response->{fees};
    my $fees_currency         = $response->{fees_currency};
    my $fees_percent          = $response->{fees_percent};
    my $derivez_currency_code = $response->{derivez_currency_code};
    my ($txn, $comment);
    try {
        my $fee_calculated_by_percent = $response->{calculated_fee};
        my $min_fee                   = $response->{min_fee};
        my $derivez_login_id          = $to_derivez =~ s/${\BOM::User->EZR_REGEX}//r;
        $comment = "Transfer from $fm_loginid to DerivEZ account $account_type $derivez_login_id";
        # transaction metadata for statement remarks
        my %txn_details = (
            derivez_account           => $derivez_login_id,
            fees                      => $fees,
            fees_percent              => $fees_percent,
            fees_currency             => $fees_currency,
            min_fee                   => $min_fee,
            fee_calculated_by_percent => $fee_calculated_by_percent
        );

        my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(%txn_details);
        $comment .= " $additional_comment" if $additional_comment;

        ($txn) = $self->client_payment(
            payment_type => 'mt5_transfer',    # We are still using mt5_transfer table for derivez
            amount       => -$amount,
            fees         => $fees,
            remark       => $comment,
            txn_details  => \%txn_details,
        );
        $self->client->user->daily_transfer_incr({
            type     => 'derivez',
            amount   => $amount,
            currency => $fm_client->currency
        });

        # We are recording derivez in mt5_transfer table
        record_derivez_transfer_to_mt5_transfer($fm_client->db->dbic, $txn->payment_id, -$response->{derivez_amount},
            $to_derivez, $response->{derivez_currency_code});

        BOM::Platform::Event::Emitter::emit(
            'transfer_between_accounts',
            {
                loginid    => $fm_client->loginid,
                properties => {
                    from_account       => $fm_loginid,
                    is_from_account_pa => 0 + !!($fm_client->is_pa_and_authenticated),
                    to_account         => $to_derivez,
                    is_to_account_pa   => 0 + !!($fm_client->is_pa_and_authenticated),
                    from_currency      => $fm_client->currency,
                    to_currency        => $derivez_currency_code,
                    from_amount        => $amount,
                    to_amount          => $response->{derivez_amount},
                    source             => $source,
                    fees               => $fees,
                    gateway_code       => 'mt5_transfer',
                    id                 => $txn->{id},
                    time               => $txn->{transaction_time}}});
    } catch ($e) {
        return create_error($error_code, {message => $e});
    }

    my $txn_id = $txn->transaction_id;
    # 31 character limit for MT5 comments
    my $derivez_comment = "${fm_loginid}_${to_derivez}#$txn_id";

    # deposit to Derivez a/c
    my $transaction_status = do_derivez_deposit($to_derivez, $response->{derivez_amount}, $derivez_comment, $txn_id);
    if ($transaction_status->{error}) {
        log_exception('derivez_deposit');
        send_transaction_email(
            loginid      => $fm_loginid,
            mt5_id       => $to_derivez,
            amount       => $amount,
            action       => 'deposit',
            error        => $transaction_status->{error},
            account_type => $account_type
        );
        return create_error($transaction_status->{code});
    } else {
        return {
            status         => 1,
            transaction_id => $txn_id,
            $return_derivez_details ? (derivez_data => $response->{derivez_data}) : ()};
    }
}

=head2 withdraw

    my $args = {
        platform => $platform,
        from_account => $to_derivez_account,
        to_account => $from_deriv_account,
        amount => $amount,
        currency => $currency
    }

    my $platform = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    my $account = $platform->withdraw($args);

=cut

sub withdraw {
    my ($self, %args) = @_;

    # Params/args from FE
    my $from_derivez = delete $args{from_account};
    my $to_loginid   = delete $args{to_account};
    my $amount       = delete $args{amount};

    # Optional Params
    my $source         = delete $args{source};
    my $currency_check = delete $args{currency_check};

    # Build client and user object
    my $client = $self->client;

    my $error_code = 'DerivEZWithdrawalError';

    return create_error('Experimental')
        if BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $client->currency);

    my $to_client = BOM::User::Client->get_client_instance($to_loginid, 'write');

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    try {
        $rule_engine->verify_action(
            'mt5_jurisdiction_validation',
            loginid         => $client->loginid,
            mt5_id          => $from_derivez,
            loginid_details => $client->user->loginid_details,
        );
    } catch ($error) {
        BOM::Platform::Event::Emitter::emit(
            'mt5_change_color',
            {
                loginid => $from_derivez,
                color   => 255,
            }) if $error->{params}->{failed_by_expiry};

        return create_error($error->{error_code});
    }

    my $response = derivez_validate_and_get_amount($client, $to_loginid, $from_derivez, $amount, $error_code, $currency_check);
    return $response if $response->{error};

    my $account_type = $response->{account_type};

    my $fees                      = $response->{fees};
    my $fees_currency             = $response->{fees_currency};
    my $fees_in_client_currency   = $response->{fees_in_client_currency};
    my $derivez_amount            = $response->{derivez_amount};
    my $fees_percent              = $response->{fees_percent};
    my $derivez_currency_code     = $response->{derivez_currency_code};
    my $fee_calculated_by_percent = $response->{calculated_fee};
    my $min_fee                   = $response->{min_fee};

    my $derivez_login_id = $from_derivez =~ s/${\BOM::User->EZR_REGEX}//r;
    my $comment          = "Transfer from DerivEZ account $account_type $derivez_login_id to $to_loginid.";

    # transaction metadata for statement remarks
    my %txn_details = (
        derivez_account           => $derivez_login_id,
        fees                      => $fees,
        fees_currency             => $fees_currency,
        fees_percent              => $fees_percent,
        min_fee                   => $min_fee,
        fee_calculated_by_percent => $fee_calculated_by_percent
    );

    my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(%txn_details);
    $comment = "$comment $additional_comment" if $additional_comment;

    # 31 character limit for MT5 comments
    my $derivez_comment = "${from_derivez}_${to_loginid}";

    my $transaction_status = do_derivez_withdrawal($from_derivez, (($amount > 0) ? $amount * -1 : $amount), $derivez_comment);
    return $transaction_status if (ref $transaction_status eq 'HASH' and $transaction_status->{error});

    try {
        # deposit to Binary a/c
        my ($txn) = $self->client_payment(
            payment_type => 'mt5_transfer',             # We are still using mt5_transfer table for derivez
            amount       => $derivez_amount,
            fees         => $fees_in_client_currency,
            remark       => $comment,
            txn_details  => \%txn_details,
        );
        $self->client->user->daily_transfer_incr({
            type     => 'derivez',
            amount   => $amount,
            currency => $derivez_currency_code
        });

        # We are recording derivez in mt5_transfer table
        record_derivez_transfer_to_mt5_transfer($to_client->db->dbic, $txn->payment_id, $amount, $from_derivez, $derivez_currency_code);

        BOM::Platform::Event::Emitter::emit(
            'transfer_between_accounts',
            {
                loginid    => $to_client->loginid,
                properties => {
                    from_account       => $from_derivez,
                    is_from_account_pa => 0 + !!($to_client->is_pa_and_authenticated),
                    to_account         => $to_loginid,
                    is_to_account_pa   => 0 + !!($to_client->is_pa_and_authenticated),
                    from_currency      => $derivez_currency_code,
                    to_currency        => $to_client->currency,
                    from_amount        => abs $amount,
                    to_amount          => $derivez_amount,
                    source             => $source,
                    fees               => $fees,
                    gateway_code       => 'mt5_transfer',
                    id                 => $txn->{id},
                    time               => $txn->{transaction_time}}});

        return {
            status         => 1,
            transaction_id => $txn->transaction_id
        };
    } catch ($e) {
        BOM::RPC::v3::Utility::log_exception('derivez_withdrawal');
        send_transaction_email(
            loginid      => $to_loginid,
            mt5_id       => $from_derivez,
            amount       => $amount,
            action       => 'withdraw',
            error        => $e,
            account_type => $account_type,
        );
        return create_error($error_code, {message => $e});
    }
}

1;
