use Object::Pad;

package BOM::User::WalletMigration;

use strict;
use warnings;

use BOM::Config::Redis;
use BOM::Platform::Event::Emitter;
use LandingCompany::Registry;
use BOM::Config::AccountType::Registry;
use BOM::Config::Runtime;

use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;

use Log::Any qw($log);

use BOM::User;
use BOM::User::Wallet;
use BOM::User::Client;

use Carp       qw(croak);
use List::Util qw(any);

use constant {
    MIGRATION_KEY_PREFIX          => 'WALLET::MIGRATION::IN_PROGRESS::',
    ELIGIBLE_CACHE_KEY_PREFIX     => 'WALLET::MIGRATION::ELIGIBLE::',
    ELIGIBLE_CACHE_TTL            => 60 * 60 * 24,                         # 1 day
    MIGRATION_TIMEOUT             => 30 * 60,                              # 30 min
    ELIGIBILITY_THRESHOLD_IN_DAYS => 90,                                   # 90 days
    SUPPORTED_TRADING_PLATFORMS   => +{
        mt5     => 1,
        dxtrade => 1,
        derivez => 1,
        ctrader => 1,
    },
};

class BOM::User::WalletMigration;

=head1 NAME

BOM::User::WalletMigration - Wallet migration class.

=head1 SYNOPSIS

    use BOM::User::WalletMigration;

    my $migration = BOM::User::WalletMigration->new(user => $user, app_id => 1);

    $migration->state();

=head1 DESCRIPTION

This class is responsible for the wallet migration process.

=head1 METHODS

=cut 

=head2 new

Creates a new instance of the class.

Arguments:

=over 4

=item * C<user>: The user object for which the wallet migration is being performed.

=item * C<app_id>: app_id from which the migration was initiated.

=back

Returns a new instance of the class.

=cut

has $user;
has $app_id;

BUILD(%args) {

    croak "Required parameter 'user' is missing" unless $args{user};

    $user = $args{user};

    croak "Required parameter 'app_id' is missing"
        unless $args{app_id}
        && $args{app_id} =~ /^\d+$/
        && $args{app_id} > 0;

    $app_id = $args{app_id};
}

=head2 redis

Returns the redis object.

=cut

method redis {
    return BOM::Config::Redis::redis_replicated_read();
}

=head2 redis_rw

Returns the redis object for write operations.

=cut

method redis_rw {
    return BOM::Config::Redis::redis_replicated_write();
}

=head2 state

Returns the state of the migration.

=cut

method state (%args) {
    return 'in_progress' if $self->redis->get(MIGRATION_KEY_PREFIX . $user->id);

    # TODO: here we need to check if user finished migration
    # probaly check against user.loginid table will be most reliable way
    # should be done as part of next card
    return 'migrated' unless $user->get_default_client->is_legacy;

    return 'failed' if keys $self->existing_wallets->%*;

    return 'eligible' if $self->is_eligible(%args);

    return 'ineligible';
}

=head2 start

The C<start> method initiates a migration process for a user. It performs several checks and then starts the migration if the conditions are met.

Returns 1 on successful initiation of the migration process.

The method may throw the following exceptions:

=over 4

=item * MigrationAlreadyInProgress

Thrown if the user is already in progress of migration.

=item * MigrationAlreadyFinished

Thrown if the user has already been migrated.

=item * UserIsNotEligibleForMigration

Thrown if the user is not eligible for migration.

=back

=cut

method start {
    my $state = $self->state(no_cache => 1);

    die {error_code => 'MigrationAlreadyInProgress'} if $state eq 'in_progress';
    die {error_code => 'MigrationAlreadyFinished'}   if $state eq 'migrated';
    die {error_code => 'UserIsNotEligibleForMigration'} unless $state eq 'eligible';

    my $is_success = $self->redis_rw->set(
        MIGRATION_KEY_PREFIX . $user->id, 1,
        EX => MIGRATION_TIMEOUT,
        "NX"
    );

    die {error_code => 'MigrationAlreadyInProgress'} unless $is_success;

    BOM::Platform::Event::Emitter::emit(
        'wallet_migration_started',
        {
            user_id => $user->id,
            app_id  => $app_id,
        });

    return 1;

}

=head2 process

The C<process> method is responsible for processing the wallet migration. It updates the migration state, 
retrieves account and login details, upgrades the accounts in a specific order, and links wallets to the trading accounts.
Returns 1 on successful processing of migration.

=head1 EXCEPTIONS

The method may throw the following exceptions:

=over 4

=item * InternalServerError

Thrown if the wallet migration was started for user with unsupported account types.

=back

=cut

method process {
    # Updates migration state on retries
    $self->redis_rw->set(
        MIGRATION_KEY_PREFIX . $user->id => 1,
        EX                               => MIGRATION_TIMEOUT
    );

    my $account_links = $user->get_accounts_links;
    my $login_details = $user->loginid_details;

    #we need to upgrade account in certain order to be able achive idenpotency
    # To be able to create wallets we need to have account details we cannot get them from mt5
    # 1. real money account CR + MF.
    # 2. real money account for trading platforms
    # 3. virtual account VRTC
    # 4. virtual account for trading platforms

    my @account_to_upgrade = $self->sort_by_priority(
        grep { !$account_links->{$_} }
            keys $login_details->%*
    );

    my $existing_wallets = $self->existing_wallets;

    for my $loginid (@account_to_upgrade) {
        my $account_info  = $login_details->{$loginid};
        my $wallet_params = $self->wallet_params_for($loginid);

        my ($lc, $type, $currency) = $wallet_params->@{qw(landing_company account_type currency)};

        my $wallet_to_link = $existing_wallets->{$lc}{$type}{$currency};

        if (!$wallet_to_link && $account_info->{platform} ne 'dtrade') {
            # technically we should not have this case in initial phase
            # because all eligible accounts should have fiat account
            # but we'll need to handle it in second phase

            $log->errorf("Wallet account wasn't created for account: %s", $loginid);
            die +{error_code => "InternalServerError"};
        }

        if (!$wallet_to_link) {
            $wallet_to_link = $self->create_wallet($wallet_params->%*);
            $existing_wallets->{$lc}{$type}{$currency} = $wallet_to_link;
        }

        # For internal trading accounts we need to update account type
        if ($wallet_params->{client}) {
            $wallet_params->{client}->account_type('standard');
            $wallet_params->{client}->save;
        }

        $user->migrate_loginid({
            loginid        => $loginid,
            wallet_loginid => $wallet_to_link->loginid,
            platform       => $account_info->{platform},
            account_type   => $account_info->{is_virtual} ? 'demo' : 'real',
        });
    }

    $self->redis_rw->del(MIGRATION_KEY_PREFIX . $user->id);

    return 1;
}

=head2 plan

The C<plan> method retrieves the migration plan for wallet migration.
It determines the accounts to upgrade and creates a migration plan containing the necessary information for creating wallets.

Returns an array reference containing the migration plan for wallet migration. Each element of the array represents an account to be created and contains the following information:

=over 4

=item * C<account_category>: The category of the account (e.g., 'wallet', 'trading').

=item * C<account_type>: The type of the account.

=item * C<platform>: The platform associated with the account.

=item * C<currency>: The currency of the account.

=item * C<landing_company_short>: The short name of the landing company associated with the account.

=item * C<link_accounts>: An array reference containing the accounts to link with the wallet (applicable only for wallet accounts).

=back

=cut

method plan {
    my %wallets_to_create;

    my $loginid_details    = $user->loginid_details;
    my @account_to_upgrade = $self->sort_by_priority(keys %$loginid_details);

    for my $loginid (@account_to_upgrade) {
        my $platform = $loginid_details->{$loginid}{platform};

        next if $platform eq 'dwallet';

        my $wallet_params = $self->wallet_params_for($loginid);
        my ($lc, $type, $currency) = $wallet_params->@{qw(landing_company account_type currency)};

        $wallets_to_create{$lc}{$type}{$currency} //= [];

        my $account_type = $platform eq 'dtrade' ? 'standard' : $platform;
        push $wallets_to_create{$lc}{$type}{$currency}->@*,
            +{
            loginid          => $loginid,
            account_category => 'trading',
            account_type     => $account_type,
            platform         => $platform,
            };
    }

    my @account_list = ();
    for my $lc (keys %wallets_to_create) {
        for my $type (keys $wallets_to_create{$lc}->%*) {
            for my $currency (keys $wallets_to_create{$lc}{$type}->%*) {
                push @account_list, +{
                    account_category      => 'wallet',
                    account_type          => $type,
                    platform              => 'dwallet',
                    currency              => $currency,
                    landing_company_short => $lc,
                    link_accounts         => $wallets_to_create{$lc}{$type}{$currency}

                };
            }
        }
    }

    return \@account_list;
}

=head2 existing_wallets

The C<existing_wallets> method retrieves the existing wallets associated with the user. 
It iterates over the user's login details and filters out the wallets that belong to the 'dwallet' platform.

Returns a hash reference containing the existing wallets associated with the user. The hash is structured as follows:

    {
        <landing_company_short> => {
            <account_type> => {
                <currency> => $wallet_object,
                ...
            },
            ...
        },
        ...
    }

Each key in the hash represents a landing company short name, and the corresponding value is another hash reference. The inner hash represents account types, and the values are the wallet objects associated with the specific combination of landing company, account type, and currency.

=cut

method existing_wallets {
    my $wallets = {};

    my $login_details = $user->loginid_details;
    for my $loginid (keys $login_details->%*) {
        next unless ($login_details->{$loginid}{platform} // '') eq 'dwallet';

        my $wallet = BOM::User::Wallet->new({loginid => $loginid});
        $wallets->{$wallet->landing_company->short}{$wallet->account_type}{$wallet->currency} = $wallet;
    }

    return $wallets;
}

=head2 create_wallet

The C<create_wallet> method creates a wallet for the user with the specified parameters.
It prepares the necessary details and invokes the appropriate method based on the landing company to create the wallet.

Arguments:

=over 4

=item * C<client>: The client object associated with the wallet.

=item * C<account_type>: The type of the account for which the wallet is being created.

=item * C<landing_company>: The landing company associated with the wallet.

=item * C<currency>: The currency for the wallet.

=back

Returns the wallet object.

=cut

method create_wallet (%args) {
    my $client       = $args{client};
    my $account_type = $args{account_type};
    my $lc           = $args{landing_company};

    my @fields_to_copy = qw(citizen salutation first_name last_name date_of_birth residence
        address_line_1 address_line_2 address_city address_state address_postcode
        phone secret_question secret_answer tax_residence tax_identification_number
        account_opening_reason place_of_birth tax_residence tax_identification_number
        non_pep_declaration_time myaffiliates_token client_password
    );

    my $type        = BOM::Config::AccountType::Registry->account_type_by_name($account_type);
    my $broker_code = $type->get_single_broker_code($lc);

    unless ($broker_code) {
        $log->errorf("Unable to get broker code for $account_type for company $lc");
        die +{error_code => "InternalServerError"};
    }

    my %details = (
        broker_code                   => $broker_code,
        account_type                  => $account_type,
        email                         => $user->email,
        myaffiliates_token_registered => 0,
        latest_environment            => '',
        currency                      => $args{currency},
        source                        => $app_id,
    );

    $details{$_} = $client->$_ for @fields_to_copy;

    # TODO: For MF we also need to copy FA, skip for now.

    my %signup_for = (
        #TODO: implement logic for maltainvest
        maltainvest => sub { die +{error_code => "NotImplemented"} },
        svg         => \&BOM::Platform::Account::Real::default::create_account,
        virtual     => \&BOM::Platform::Account::Virtual::create_account,
    );

    my $result = $signup_for{$lc}->(
        +{
            details => \%details,
            user    => $user,
        });

    if ($result->{error}) {
        $log->errorf("Unable to create wallet for user %s with error %s", $user->id, $result->{error});
        die +{error_code => "InternalServerError"};
    }

    delete $user->{loginid_details};

    return $result->{client};
}

=head2 reset

The C<reset> method is used to reset a failed wallet migration. 
It checks if the current state of the migration is 'failed' and performs the necessary steps to reset the migration.

The method may throw the following exception:

=over 4

=item * MigrationNotFailed

Thrown if the migration is not in a 'failed' state. Resetting can only be done when the migration has failed.

=back

IMPLEMENTATION NOTES:

The implementation of the reset logic is pending and is not yet implemented.


=cut

method reset {
    die +{error_code => 'MigrationNotFailed'} unless $self->state eq 'failed';

    #TODO: implement logic for reset
    die +{error_code => 'NotImplemented'};
}

=head2 is_eligible

The C<is_eligible> method checks if the user is eligible for wallet migration based on specific criteria. 

Returns a boolean value indicating whether the user is eligible for wallet migration. 
A return value of 1 indicates eligibility, while 0 indicates ineligibility.

=cut

method is_eligible (%args) {
    # Check if wallet feature is enabled
    return 0 if BOM::Config::Runtime->instance->app_config->system->suspend->wallets;

    unless ($args{no_cache}) {
        my $cached_result = $self->redis->get(ELIGIBLE_CACHE_KEY_PREFIX . $user->id);

        return $cached_result if defined $cached_result;
    }

    my $is_eligible = ($self->check_eligibility_for_user && $self->check_eligibility_for_real_dtrade_accounts) ? 1 : 0;

    $self->redis_rw->set(ELIGIBLE_CACHE_KEY_PREFIX . $user->id, $is_eligible, EX => ELIGIBLE_CACHE_TTL);

    return $is_eligible;
}

=head2 check_eligibility_for_user

The C<check_eligibility_for_user> method checks if the user is eligible for wallet migration.

Returns a boolean value indicating whether the user is eligible for wallet migration.

=cut

method check_eligibility_for_user () {
    # Start with checks on user level to minimize number of db calls
    # and fail fast based on information which we already have
    my @accounts = values $user->loginid_details->%*;

    # clients without virtual account are not eligible for now
    return 0 unless any { $_->{platform} eq 'dtrade' && $_->{is_virtual} } @accounts;

    my @real_dtrade_accounts = grep { $_->{platform} eq 'dtrade' && !$_->{is_virtual} } @accounts;

    return 0 unless @real_dtrade_accounts;

    # MF client out of scope for now
    return 0 if any { $_->{platform} eq 'dtrade' && $_->{loginid} =~ /^MF/ } @real_dtrade_accounts;

    return 1;
}

=head2 check_eligibility_for_real_dtrade_accounts

The C<check_eligibility_for_real_dtrade_accounts> method checks if the user's dtrade accounts eligible for wallet migration.

Returns a boolean value indicating whether the user has eligible accounts for wallet migration.

=cut

method check_eligibility_for_real_dtrade_accounts () {
    my ($has_eligible_country, $has_eligible_usd_account);

    for my $loginid ($user->bom_real_loginids) {
        my $client = BOM::User::Client->get_client_instance($loginid);

        return 0 unless $client->landing_company->short eq 'svg';

        next if $client->is_wallet;

        unless ($has_eligible_country) {
            my $country = $client->residence;
            return 0 unless $country;

            return 0 unless $self->check_eligibility_for_country($country);

            $has_eligible_country = 1;
        }

        my $acc = $client->default_account;

        # If client has currency selected
        return 0 unless $acc;

        return 0 if $client->payment_agent;

        my ($pa_net) = $client->db->dbic->run(
            fixup => sub {
                return $_->selectrow_array('SELECT payment.aggregate_payments_by_type(?, ?, ?)',
                    undef, $acc->id, 'payment_agent_transfer', ELIGIBILITY_THRESHOLD_IN_DAYS);
            });

        return 0 if defined $pa_net;

        if ($acc->currency_code eq 'USD') {
            return 0 unless $self->check_eligibility_for_usd_dtrade_account($client);
            $has_eligible_usd_account = 1;
        }
    }

    # No migration if client doesn't have fiat usd account
    return 0 unless $has_eligible_usd_account;

    return 1;
}

=head2 check_eligibility_for_usd_dtrade_account

This method checks if a USD DTrade account is eligible for migration. 
It performs a series of checks on the account's age, payment agent net, and P2P advertiser status to determine 
if the account meets the criteria for migration.

Arguments:

=over 4

=item * C<$client_usd>: The client object associated with the USD account.

=back

Returns a boolean value indicating whether the USD account is eligible for migration.

=cut

method check_eligibility_for_usd_dtrade_account ($client_usd) {
    # No migration who is younger than 90 days
    my $days_since_signup = (time - Date::Utility->new($client_usd->date_joined)->epoch) / (24 * 60 * 60);
    return 0 if $days_since_signup < ELIGIBILITY_THRESHOLD_IN_DAYS;

    # probably stupid idea to use private method over here
    # but it provides exactly check we need
    return 0 if $client_usd->_p2p_advertiser_cached;

    return 1;
}

=head2 check_eligibility_for_country

This method checks if the wallet migration can be is available in a given country. 

Arguments:

=over 4

=item * C<$country>: The country for which the check is being performed.

=back

Returns a boolean value indicating whether the wallet migration is available in the given country.

=cut

method check_eligibility_for_country ($country) {
    # Check that we launched wallet at client residence country
    my $countries = Brands->new()->countries_instance;
    for my $wallet_type (qw/real virtual/) {
        my $wallet_complanies = $countries->wallet_companies_for_country($country, $wallet_type) // [];

        return 0 unless $wallet_complanies->@*;

        # MF supported countries corrently out of scope for now
        return 0 if any { $_ eq 'maltainvest' } $wallet_complanies->@*;
    }

    return 1;
}

=head2 wallet_params_for

Returns the wallet params for the given loginid.

The C<wallet_params_for> method retrieves the wallet parameters for a given login ID. 
It determines the account type, landing company, currency, and other relevant details based on the login ID's platform and type.

The method may throw the following exception:

=over 4

=item * InternalServerError

If loging id belongs to unsupported platform.

=back

Returns a hash reference containing the wallet parameters for the given login ID. The hash reference contains the following keys:

=over 4

=item * C<account_type>: The type of the account associated with the login ID.

=item * C<landing_company>: The short name of the landing company associated with the login ID.

=item * C<currency>: The currency associated with the login ID.

=item * C<client>: The client object associated with the login ID (applicable for dtrade platform).

=back

=cut

method wallet_params_for ($loginid) {
    my $account_info = $user->loginid_details->{$loginid};

    # Trading platforms
    if (SUPPORTED_TRADING_PLATFORMS->{$account_info->{platform}}) {
        # for initial phase it will be only DF wallet for all trading platforms
        # int future we need to implement logic to hande different variations

        # Real money account
        return +{
            account_type    => 'doughflow',
            landing_company => 'svg',
            currency        => 'USD',
        } unless $account_info->{is_virtual};

        # Demo account
        return +{
            account_type    => 'virtual',
            landing_company => 'virtual',
            currency        => 'USD',
        };
    }

    if ($account_info->{platform} ne 'dtrade') {
        $log->errorf("Unable to get wallet params for loginid %s as part of wallet migration", $loginid);
        die +{error_code => "InternalServerError"};
    }

    # Deriv accounts: VRTC, CR and MF
    my $client   = BOM::User::Client->new({loginid => $loginid});
    my $currency = $client->currency;

    return +{
        account_type    => 'virtual',
        landing_company => $client->landing_company->short,
        currency        => $currency,
        client          => $client,
        }
        if $account_info->{is_virtual};

    my $type = LandingCompany::Registry::get_currency_type($currency) eq 'crypto' ? 'crypto' : 'doughflow';

    return +{
        account_type    => $type,
        landing_company => $client->landing_company->short,
        currency        => $currency,
        client          => $client,
    };
}

=head2 sort_by_priority

The C<sort_by_priority> method sorts the provided login IDs based on their priority. 
It uses a cache to store the priority value for each login ID, ensuring efficient sorting.

Arguments:

The C<sort_by_priority> method expects the following parameter:

=over 4

=item * C<@loginids>: An array of login IDs to be sorted.

=back

In list context, the method returns an array containing the login IDs sorted by priority. In scalar context, the function throws an exception.

=cut

method sort_by_priority (@loginids) {
    croak "Can't sort in scalar context" unless wantarray;

    my %cache;
    my @sorted_loginids = sort { ($cache{$a} //= $self->priority_for($a)) <=> ($cache{$b} //= $self->priority_for($b)) } @loginids;

    return @sorted_loginids;
}

=head2 priority_for

The C<priority_for> method determines the priority for an account based on the provided login ID.
It uses the platform and type information obtained from the login ID to assign a priority value.

Arguments:

=over 4

=item * C<$loginid>: The login ID for which the priority is being determined.

=back

Returns an integer representing the priority value for the account.
Lower values indicate higher priority.
The priority values are assigned as follows:

=cut

method priority_for ($loginid) {
    my $account_info = $user->loginid_details->{$loginid};

    if ($account_info->{platform} eq 'dtrade') {
        return $account_info->{is_virtual} ? 3 : 1;
    }

    return $account_info->{is_virtual} ? 4 : 2;
}

1;
