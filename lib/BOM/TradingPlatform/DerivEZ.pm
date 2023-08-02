package BOM::TradingPlatform::DerivEZ;

use strict;
use warnings;
no indirect;

use BOM::Platform::Context qw (localize request);
use BOM::Rules::Engine;
use BOM::MT5::User::Async;
use Syntax::Keyword::Try;
use Format::Util::Numbers      qw/financialrounding formatnumber/;
use Log::Any                   qw($log);
use List::Util                 qw(any first);
use DataDog::DogStatsd::Helper qw/stats_inc/;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw (request);
use BOM::User::Client;
use LandingCompany::Registry;
use BOM::TradingPlatform::Helper::HelperDerivEZ qw(
    new_account_trading_rights
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
    get_transfer_fee_remark
);

use constant DERIVEZ_SVG_FINANCIAL_MOCK_LEVERAGE => 1;
use constant DERIVEZ_SVG_FINANCIAL_REAL_LEVERAGE => 1000;

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
    validate_new_account_params(%args);

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

    # MT5 account creation should be only available for wallets and legacy account type
    die +{code => 'permission'} unless $client->is_wallet || $client->is_legacy;

    my $rule_engine         = BOM::Rules::Engine->new(client => $client);
    my $binary_company_name = get_landing_company($client);

    # Checking the new derivez account creation rule
    $rule_engine->verify_action(
        'new_mt5_dez_account',
        loginid      => $client->loginid,
        account_type => $account_type,
        regulation   => $binary_company_name,
        platform     => 'derivez',
    );

    # Build client params if missing
    unless ($landing_company_short) {
        try {
            $landing_company_short = $client->landing_company->short;
        } catch {
            if (not defined $landing_company_short) {
                $landing_company_short = get_derivez_landing_company($client);
                die +{
                    code   => $landing_company_short->{error},
                    params => [$client->residence]} if $landing_company_short->{error};
            }
        }
    }

    # Validate if the client's country support derivez account creation
    my $all_company_landing_company = get_derivez_landing_company($client);
    unless ($all_company_landing_company) {
        die +{code => 'DerivEZNotAllowed'};
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
    die +{code => 'DerivEZInvalidAccountCurrency'} if $account_currency ne $selected_currency;

    # Innitialize params
    my $client_info       = $client->get_mt5_details();
    my $main_password     = generate_password($client->user->{password});
    my $investor_password = generate_password($client->user->{password});
    my $rights            = new_account_trading_rights();
    my $group             = derivez_group({
        residence             => $client->residence,
        landing_company_short => $landing_company_short,
        account_type          => $account_type,
        currency              => $account_currency,
    });

    my $link_to_wallet;
    if ($client->is_wallet) {
        # Wallet flow
        my $wallet_landing_company = $account_type eq 'demo' ? 'virtual' : $binary_company_name;

        return die +{
            error_code     => 'TradingPlatformInvalidAccount',
            message_params => ['DerivEZ']}
            unless $client->landing_company->short eq $wallet_landing_company;

        $link_to_wallet = $client->loginid;
    } else {
        # Legacy flow
        return die +{
            error_code     => 'TradingPlatformInvalidAccount',
            message_params => ['DerivEZ']} unless $client->is_legacy;

        # Add a switch to a qualified accounts
        if ($account_type ne 'demo' and $client->landing_company->short ne $binary_company_name) {
            my @clients = $user->clients_for_landing_company($binary_company_name);
            # remove disabled/duplicate accounts to make sure that atleast one Real account is active
            @clients = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
            $client  = (@clients > 0) ? $clients[0] : undef;
        }

        # Check if a real mt5 accounts was being created with no real binary account existing
        die +{code => 'DerivEZRealAccountMissing'}
            if ($account_type ne 'demo' and scalar($user->clients) == 1 and $client->is_virtual());
    }

    # Disable trading for affiliate accounts
    $rights = affiliate_trading_rights() if $client->landing_company->is_for_affiliates;

    # Disable trading for payment agents
    $rights = payment_agent_trading_rights() if (defined $client->payment_agent && $client->payment_agent->status eq 'authorized');

    # Get the group settings
    my $group_setting = BOM::MT5::User::Async::get_group($group)->catch(
        sub {
            return shift;
        })->get;
    die +{code => $group_setting->{code}} if $group_setting->{error};

    $group_setting->{leverage} = DERIVEZ_SVG_FINANCIAL_REAL_LEVERAGE if $group_setting->{leverage} == DERIVEZ_SVG_FINANCIAL_MOCK_LEVERAGE;

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
    validate_user($client, $new_account_params,);

    # This is for dry run mode
    return {
        account_type    => $account_type,
        balance         => 0,
        currency        => 'USD',
        display_balance => '0.00'
    } if $dry_run;

    # We need to make sure the client dont have multiple account in one trade server
    derivez_accounts_lookup($client, $account_type)->then(
        sub {
            my (@logins) = @_;

            my (%existing_groups, $trade_server_error, $has_hr_account);

            # Loop through the list of accounts
            foreach my $derivez_account (@logins) {
                # Check for errors with the MT5 server
                unless ($derivez_account) {
                    die +{
                        code    => 'DerivEZCreateUserError',
                        message => localize('Some accounts are currently unavailable. Please try again later.')};
                }

                if (defined($derivez_account->{code})) {
                    $trade_server_error = $derivez_account;
                    last;
                }

                # Keep track of the existing groups
                $existing_groups{$derivez_account->{group}} = $derivez_account->{login} if $derivez_account->{group};

                # Check if the client has a high-risk account
                $has_hr_account = 1 if lc($derivez_account->{group}) =~ /synthetic/ and lc($derivez_account->{group}) =~ /(\-hr|highrisk)/;
            }

            # Handle errors with the MT5 server
            if ($trade_server_error) {
                die +{
                    code    => 'DerivEZCreateUserError',
                    message => $trade_server_error->{message}};
            }

            # If one of client's account has been moved to high-risk groups
            # client shouldn't be able to open a non high-risk account anymore
            # so, here we set convert the group to high-risk version of the selected group if applicable
            if ($has_hr_account and $account_type ne 'demo' and $group =~ /synthetic/ and not $group =~ /\-/) {
                my ($division) = $group =~ /\\[a-zA-Z]+_([a-zA-Z]+)_/;
                my $new_group = $group =~ s/$division/$division-hr/r;

                # Remove the counter for SVG HR groups
                $new_group =~ s/\\\d+$//;

                # Check if the high-risk group exists
                if (get_derivez_account_type_config($new_group)) {
                    $group = $new_group;
                } else {
                    # Handle the case where the high-risk group does not exist
                    $log->warnf("Unable to find high risk group %s for client %s with original group of %s.", $new_group, $client->loginid, $group);

                    die +{code => 'DerivEZCreateUserError'};
                }
            }

            # Check for duplicates of the selected group
            if (my $identical = is_identical_group($group, \%existing_groups)) {
                die +{code => 'DerivEZDuplicate'};
            }
        })->get;

    # Create a DerivEZ account for a user
    return BOM::MT5::User::Async::create_user($new_account_params)->then(
        sub {
            my ($status) = shift;

            # Extract account details from the response
            my $derivez_login = $status->{login};
            my ($derivez_currency, $derivez_leverage) = @{$new_account_params}{qw/currency leverage/};
            my $account_type = is_account_demo($new_account_params->{group}) ? 'demo' : 'real';

            # Define additional account attributes
            my $derivez_attributes = {
                group           => $group,
                landing_company => $binary_company_name,
                currency        => $derivez_currency,
                market_type     => $market_type,
                account_type    => $account_type,
                leverage        => $derivez_leverage
            };

            # Add DerivEZ account to user's login IDs
            $user->add_loginid($derivez_login, 'derivez', $account_type, $derivez_currency, $derivez_attributes, $link_to_wallet);

            # Link new client to affiliate (if applicable)
            my $group_config = get_derivez_account_type_config($group);
            die +{code => 'permission'} unless $group_config;

            if ($client->myaffiliates_token and $account_type ne 'demo') {
                BOM::Platform::Event::Emitter::emit(
                    'link_myaff_token_to_mt5',
                    {
                        client_loginid     => $client->loginid,
                        client_mt5_login   => $derivez_login,
                        myaffiliates_token => $client->myaffiliates_token,
                        server             => $group_config->{server}});
            }

            # Deposit virtual funds into the new account (if it's a demo account)
            my $balance = 0;
            if ($account_type eq 'demo') {
                $balance = 10000;
                do_derivez_deposit($derivez_login, $balance, 'DerivEZ Virtual Money deposit');
            }

            # Return account details
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
        }
    )->catch(
        sub {
            my $error = shift;

            # Check for errors
            if ($error->{error}) {
                # Handle permissions error
                die +{code => 'permission'} if $error->{error} =~ /Not enough permissions/;
                # Handle other errors
                die +{
                    code    => 'DerivEZCreateUserError',
                    message => $error->{error}};
            }

            # Handle the error appropriately, such as logging it or throwing a custom error
            die +{code => 'DerivEZCreateUserError'};
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

    my $error_code = 'DerivEZDepositError';
    my $response   = derivez_validate_and_get_amount($client, $fm_loginid, $to_derivez, $amount, $error_code);

    # Parameters
    my $account_type              = $response->{account_type};
    my $fees                      = $response->{fees};
    my $fees_currency             = $response->{fees_currency};
    my $fees_percent              = $response->{fees_percent};
    my $derivez_currency_code     = $response->{derivez_currency_code};
    my $fee_calculated_by_percent = $response->{calculated_fee};
    my $min_fee                   = $response->{min_fee};
    my $derivez_login_id          = $to_derivez =~ s/${\BOM::User->EZR_REGEX}//r;
    my ($txn, $comment);

    if ($response->{top_up_virtual}) {
        # This if for virtual topup
        my $amount_to_topup = 10000;

        my $top_up_virtual_status = do_derivez_deposit($to_derivez, $amount_to_topup, 'DerivEZ Virtual Money deposit');
        if ($top_up_virtual_status->{error}) {
            die +{code => $top_up_virtual_status->{code}} if $top_up_virtual_status->{error};
        } else {
            return {status => 1};
        }
    } else {
        # This status is intended to block withdrawals from binary to MT5
        # For DerivEZ we are still using mt5 as the BE trade server
        if (    $client->status->mt5_withdrawal_locked
            and $client->status->mt5_withdrawal_locked->{'reason'} =~ /FA is required for the first deposit on regulated MT5./g)
        {
            die +{code => 'FinancialAssessmentRequired'};
        } elsif ($client->status->mt5_withdrawal_locked) {
            die +{
                code          => 'WithdrawalLocked',
                override_code => $error_code
            };
        }

        $account_type = $response->{account_type};
    }

    # Populate required variables
    my $fm_client = BOM::User::Client->get_client_instance($fm_loginid, 'write');
    my $balance   = $fm_client->default_account->balance;

    # Checks if balance is exceeded
    die +{
        code    => $error_code,
        message => localize("The maximum amount you may transfer is: [_1].", $balance)}
        if $balance > 0
        and $amount > $balance;

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
            die +{
                code    => $error_code,
                message => $e->{message_to_client}};
        };
    }

    # We will deduct the ammount on our side and record it into our DB
    try {
        # The comments that we store in DB under transaction.transaction table
        $comment = "Transfer from $fm_loginid to DerivEZ account $account_type $derivez_login_id";

        # Transaction metadata for statement remarks
        my %txn_details = (
            derivez_account           => $derivez_login_id,
            fees                      => $fees,
            fees_percent              => $fees_percent,
            fees_currency             => $fees_currency,
            min_fee                   => $min_fee,
            fee_calculated_by_percent => $fee_calculated_by_percent
        );

        my $additional_comment = get_transfer_fee_remark(%txn_details);
        $comment .= " $additional_comment" if $additional_comment;

        # Record payment tranfer to our DB using payment.add_payment_transaction
        ($txn) = $self->client_payment(
            payment_type => 'mt5_transfer',    # We are still using mt5_transfer table for derivez
            amount       => -$amount,
            fees         => $fees,
            remark       => $comment,
            txn_details  => \%txn_details,
        );

        # Daily transfer limit increment
        $self->client->user->daily_transfer_incr({
            type     => 'derivez',
            amount   => $amount,
            currency => $fm_client->currency
        });

        # We are recording derivez in mt5_transfer table
        record_derivez_transfer_to_mt5_transfer($fm_client->db->dbic, $txn->payment_id, -$response->{derivez_amount},
            $to_derivez, $response->{derivez_currency_code});

        # Tracking transfer for data manipulation purposes
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
        stats_inc("derivez.deposit.error", {tags => ["login:$to_derivez", "code:record_fail"]});

        die +{
            code    => $error_code,
            message => $e
        };
    }

    # 31 character limit for MT5 comments
    my $txn_id          = $txn->transaction_id;
    my $derivez_comment = "${fm_loginid}#$txn_id";

    # deposit to Derivez a/c
    try {
        do_derivez_deposit($to_derivez, $response->{derivez_amount}, $derivez_comment, $txn_id);

        return {
            status         => 1,
            transaction_id => $txn_id,
            $return_derivez_details ? (derivez_data => $response->{derivez_data}) : ()};
    } catch ($e) {
        send_transaction_email(
            loginid      => $fm_loginid,
            mt5_id       => $to_derivez,
            amount       => $amount,
            action       => 'deposit',
            error        => $e->{error},
            account_type => $account_type
        );
        die +{code => $e->{code}};
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

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    try {
        $rule_engine->verify_action(
            'mt5_jurisdiction_validation',
            loginid         => $client->loginid,
            mt5_id          => $from_derivez,
            loginid_details => $client->user->loginid_details,
        );
    } catch ($e) {
        BOM::Platform::Event::Emitter::emit(
            'mt5_change_color',
            {
                loginid => $from_derivez,
                color   => 255,
            }) if $e->{params}->{failed_by_expiry};

        die +{
            code    => $e->{error_code},
            message => $e
        };
    }

    my $error_code = 'DerivEZWithdrawalError';
    my $response   = derivez_validate_and_get_amount($client, $to_loginid, $from_derivez, $amount, $error_code, $currency_check);

    # Parameters
    my $account_type              = $response->{account_type};
    my $fees                      = $response->{fees};
    my $fees_currency             = $response->{fees_currency};
    my $fees_in_client_currency   = $response->{fees_in_client_currency};
    my $derivez_amount            = $response->{derivez_amount};
    my $fees_percent              = $response->{fees_percent};
    my $derivez_currency_code     = $response->{derivez_currency_code};
    my $fee_calculated_by_percent = $response->{calculated_fee};
    my $min_fee                   = $response->{min_fee};
    my $derivez_login_id          = $from_derivez =~ s/${\BOM::User->EZR_REGEX}//r;
    my $comment                   = "Transfer from DerivEZ account $account_type $derivez_login_id to $to_loginid.";

    # Populate required variables
    my $to_client = BOM::User::Client->get_client_instance($to_loginid, 'write');

    # transaction metadata for statement remarks
    my %txn_details = (
        derivez_account           => $derivez_login_id,
        fees                      => $fees,
        fees_currency             => $fees_currency,
        fees_percent              => $fees_percent,
        min_fee                   => $min_fee,
        fee_calculated_by_percent => $fee_calculated_by_percent
    );

    my $additional_comment = get_transfer_fee_remark(%txn_details);
    $comment = "$comment $additional_comment" if $additional_comment;

    # 31 character limit for MT5 comments
    my $derivez_comment = "${from_derivez}_${to_loginid}";

    # Do withdrawal using API call from Derivez to CR account
    do_derivez_withdrawal($from_derivez, (($amount > 0) ? $amount * -1 : $amount), $derivez_comment)->get;

    # Record the transfer after we have deducted from server
    try {
        # Record payment tranfer to our DB using payment.add_payment_transaction
        my ($txn) = $self->client_payment(
            payment_type => 'mt5_transfer',
            amount       => $derivez_amount,
            fees         => $fees_in_client_currency,
            remark       => $comment,
            txn_details  => \%txn_details,
        );

        # Daily transfer limit increment
        $self->client->user->daily_transfer_incr({
            type     => 'derivez',
            amount   => $amount,
            currency => $derivez_currency_code
        });

        # We are recording derivez in mt5_transfer table
        record_derivez_transfer_to_mt5_transfer($to_client->db->dbic, $txn->payment_id, $amount, $from_derivez, $derivez_currency_code);

        # Tracking transfer for data manipulation purposes
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
        stats_inc("derivez.withdrawal.error", {tags => ["login:$from_derivez", "code:record_fail"]});
        send_transaction_email(
            loginid      => $to_loginid,
            mt5_id       => $from_derivez,
            amount       => $amount,
            action       => 'withdraw',
            error        => $e,
            account_type => $account_type,
        );
        die +{
            code    => $error_code,
            message => $e
        };
    }
}

=head2 get_account_info

The DerivEZ implementation of getting an account info by loginid.

=over 4

=item * C<$loginid> - an DerivEZ loginid

=back

Returns a object holding an DerivEZ account info on success, throws exception on error

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    my ($derivez_login) = $self->client->user->get_derivez_loginids(loginid => $loginid);

    die "InvalidDerivEZAccount\n" unless $derivez_login;

    try {
        my $derivez_user  = BOM::MT5::User::Async::get_user($derivez_login)->get;
        my $derivez_group = BOM::User::Utility::parse_mt5_group($derivez_user->{group});
        my $currency      = uc($derivez_user->{currency});

        return +{
            account_id            => $derivez_user->{login},
            account_type          => $derivez_group->{account_type},
            balance               => financialrounding('amount', $currency, $derivez_user->{balance}),
            currency              => $currency,
            display_balance       => formatnumber('amount', $currency, $derivez_user->{balance}) // '0.00',
            platform              => 'derivez',
            market_type           => $derivez_group->{market_type},
            landing_company_short => $derivez_group->{landing_company_short},
            sub_account_type      => $derivez_group->{sub_account_type},
        };
    } catch ($e) {
        die "InvalidDerivEZAccount\n" if (ref $e eq 'HASH') && (($e->{code} // '') eq 'NotFound');

        die $e;
    }
}

1;
