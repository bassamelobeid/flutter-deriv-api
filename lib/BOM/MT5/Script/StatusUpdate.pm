package BOM::MT5::Script::StatusUpdate;

use strict;
use warnings;

use Object::Pad;
use BOM::Database::UserDB;
use BOM::MT5::User::Async;
use Date::Utility;
use BOM::Config;
use BOM::User::Client;
use List::Util qw(uniq min max);
use Log::Any   qw($log);
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use Brands;
use JSON::MaybeXS                    qw(decode_json);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw(financialrounding);
use Future;
use Future::AsyncAwait;
use Time::Moment;
use BOM::User::Client::AuthenticationDocuments::Config;
use DataDog::DogStatsd::Helper qw(stats_event);
use Data::Dump                 qw(pp);
use BOM::Config::MT5;

use constant DISABLE_ACCOUNT_DAYS       => 30;
use constant SECOND_REMINDER_EMAIL_DAYS => 20;
use constant FIRST_REMINDER_EMAIL_DAYS  => 10;
use constant BVI_EXPIRATION_DAYS        => 10;
use constant BVI_WARNING_DAYS           => 8;
use constant VANUATU_EXPIRATION_DAYS    => 5;      # Need to consider the accounts created on the day until 23:59:59
use constant VANUATU_WARNING_DAYS       => 3;
use constant COLOR_RED                  => 255;    # BGR (0,0,255)
use constant RETRY_LIMIT                => 5;
use constant ACCOUNTS_BATCH_SIZE        => 1000;

=head1 BOM::MT5::Script::StatusUpdate

This module is used to gather clients with pending or rejected 
and process them, changes their status, updating trading rights,
disables accounts, sends emails and warnings

=head1 SYNOPSIS

The methods that are used to process the clients are

grace_period_actions
disable_users_actions
sync_status_actions
send_reminder_emails
send_expiration_emails
check_poa_issuance

=cut 

class BOM::MT5::Script::StatusUpdate {

    my $userdb;

    my %parsed_mt5_account;
    my %parsed_binary_user_id;
    my $user_loaded;

    my $now;
    my $bvi_warning_timestamp;
    my $bvi_expiration_timestamp;
    my $vanuatu_warning_timestamp;
    my $vanuatu_expiration_timestamp;
    my $emails;

=head2 new

Initialize db and dates

Does not take or return any parameters

=cut

    BUILD {

        $userdb      = BOM::Database::UserDB::rose_db();
        $user_loaded = 0;

        $now                          = Date::Utility->today;
        $bvi_warning_timestamp        = $now->minus_time_interval(BVI_WARNING_DAYS . 'd');
        $bvi_expiration_timestamp     = $now->minus_time_interval(BVI_EXPIRATION_DAYS . 'd');
        $vanuatu_warning_timestamp    = $now->minus_time_interval(VANUATU_WARNING_DAYS . 'd');
        $vanuatu_expiration_timestamp = $now->minus_time_interval(VANUATU_EXPIRATION_DAYS . 'd');

        $emails = {
            poa_verification_expired         => 1,
            poa_verification_warning         => 1,
            poa_verification_failed_reminder => 1
        };

    }

=head2 record_mt5_transfer

Records the transfer from MT5 to CR account in the database

=over 4

=item * C<$params> Hashref that contains dbic, payment_id, mt5_amount, mt5_account_id, mt5_currency fields

=back

Returns a hashref with result => 1 if record was successfull
or a hashref with error field descibing the error

=cut

    method record_mt5_transfer {
        my $params = shift;
        return $self->return_error("record_mt5_transfer", "No parameters passed") unless ($params);

        my $dbic           = $params->{dbic};
        my $payment_id     = $params->{payment_id};
        my $mt5_amount     = $params->{mt5_amount};
        my $mt5_account_id = $params->{mt5_account_id};
        my $mt5_currency   = $params->{mt5_currency};

        try {
            $dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        'INSERT INTO payment.mt5_transfer
                        (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
                        VALUES (?,?,?,?)'
                    );
                    $sth->execute($payment_id, $mt5_amount, $mt5_account_id, $mt5_currency);
                });

            return +{result => 1};
        } catch ($e) {
            return $self->return_error("record_mt5_transfer", "Cant record transfer from $mt5_account_id: $e");
        }
    }

=head2 change_color_to_red

Changes account color to red in MT5 side, representing that is a restricted in trading rights account

=over 4

=item * C<$mt5_account> The loginid of the MT5 account

=back

Returns the status of the operation from BOM::Platform::Event::Emitter
or a hashref with error field describing the failure

=cut

    method change_color_to_red {
        my $mt5_account = shift;
        return $self->return_error("change_color_to_red", "No parameters passed") unless ($mt5_account);

        try {
            return BOM::Platform::Event::Emitter::emit(
                'mt5_change_color',
                {
                    loginid => $mt5_account,
                    color   => COLOR_RED
                });
        } catch ($e) {
            return $self->return_error("change_color_to_red", "Could not update loginid $mt5_account account color: $e");
        }
    }

=head2 update_loginid_status

Changes the status of the client in user.loginid table

=over 4

=item * C<$params> Hashref that contains binary_user_id, loginid, to_status, fields

=back

Returns the status of the operation from BOM::Platform::Event::Emitter
or a hashref with error field describing the failure

=cut

    method update_loginid_status ($params) {
        return $self->return_error("update_loginid_status", "No parameters passed") unless ($params);
        my $binary_user_id = $params->{binary_user_id};
        my $loginid        = $params->{loginid};
        my $to_status      = $params->{to_status};

        $self->dd_log_info('update_loginid_status', "Updating status for $loginid");
        try {
            return BOM::Platform::Event::Emitter::emit(
                'update_loginid_status',
                {
                    binary_user_id => $binary_user_id,
                    loginid        => $loginid,
                    status_code    => $to_status
                });
        } catch ($e) {
            return $self->return_error("update_loginid_status", "Could not update loginid $loginid status: $e");
        }

    }

=head2 send_email_to_client

Sends email to client

=over 4

=item * C<$params> Hashref that contains email_type, email_paramsfields

=item * C<$params{email_params}> Hashref that contains loginid and any other email related fields

=back

Returns the status of the operation from BOM::Platform::Event::Emitter
or 0 in case if the email was not sent

=cut

    method send_email_to_client ($params) {

        my $email_type   = $params->{email_type};
        my $email_params = $params->{email_params};

        return return $self->return_error("send_email_to_client", "No parameters passed") unless ($email_type and $emails->{$email_type});
        $self->dd_log_info('send_email_to_client', 'Sending email: ' . pp($params));
        return BOM::Platform::Event::Emitter::emit($email_type => $email_params);
    }

=head2 parse_user

Parsing user data fetched from db 

=over 4

=item * C<$data> Arrayref that contains loginid, binary_user_id, creation_stamp, status, platform, account_type, currency, attributes fields

=back

Returns a hashref with the following fields:

loginid  
binary_user_id  
creation_stamp 
status          
group       

=cut

    method parse_user ($data) {
        return $self->return_error("parse_user", "No parameters passed") unless ($data);

        my ($loginid, $binary_user_id, $creation_stamp, $status, $platform, $account_type, $currency, $attributes) = @$data;

        try {
            $attributes     = decode_json($attributes);
            $creation_stamp = Date::Utility->new($creation_stamp);
        } catch ($e) {
            return $self->return_error("parse_user", "Error while parsing user: $e");
        }
        if (not $loginid or not $binary_user_id or not $attributes->{group}) {
            return $self->return_error("parse_user", "Missing loginid, binary_user_id or group");
        }

        return +{
            loginid        => $loginid,
            binary_user_id => $binary_user_id,
            creation_stamp => $creation_stamp,
            status         => $status,
            group          => $attributes->{group}};
    }

=head2 load_all_user_data

Load additional client data. The reason to have this sub is to separate it from the parse_user which is lite
Here instance of BOM::User and BOM::User::Client are created which is not always required

=over 4

=item * C<$data> Arrayref that contains loginid, binary_user_id, creation_stamp, status, platform, account_type, currency, attributes fields

=back

Returns a hashref with the following fields:

user (BOM::User object)
client (BOM::User::Client object)
bom_loginid 
cr_currency 

=cut

    method load_all_user_data ($binary_user_id) {

        return $self->return_error("load_all_user_data", "No parameters passed") unless ($binary_user_id);
        $self->dd_log_info('load_all_user_data', "Loading user data for user with binary_user_id: $binary_user_id");

        # prefer fiat currencies
        my %fiat_currencies = (
            'USD' => 1,
            'EUR' => 1,
            'AUD' => 1,
            'GBP' => 1
        );

        my ($user, $bom_loginid, $client, $cr_currency);
        try {
            $user = BOM::User->new((id => $binary_user_id));
            my @bom_real_loginids = $user->bom_real_loginids;

            foreach my $loginid (@bom_real_loginids) {
                my $bom_client = BOM::User::Client->new({loginid => $loginid});

                # active accounts only
                if ($bom_client->is_available) {

                    if ($fiat_currencies{$bom_client->currency}) {
                        $client      = $bom_client;
                        $bom_loginid = $client->loginid;
                        $cr_currency = $client->currency;
                        last;
                    }

                    $client      = $bom_client;
                    $bom_loginid = $client->loginid;
                    $cr_currency = $client->currency;
                }
            }

        } catch ($e) {
            return $self->return_error("load_all_user_data", "Cant load user data: $e")
        }

        return +{
            user        => $user,
            bom_loginid => $bom_loginid,
            client      => $client,
            cr_currency => $cr_currency
        };

    }

=head2 get_mt5_accounts_under_same_jurisdiction

Required to disable all mt5 accounts which are under the same jurisdiction,
Takes the jurisdiction and the user object

=over 4

=item * C<$params> Arrayref that contains jurisdiction, user fields

=back

Returns a array with the loginids under the same jurisdiction for a user

=cut

    method get_mt5_accounts_under_same_jurisdiction ($params) {
        return $self->return_error("get_mt5_accounts_under_same_jurisdiction", "No parameters passed") unless ($params);

        my $jurisdiction = $params->{jurisdiction};
        my $user         = $params->{user};

        my @mt5_accounts;
        my $loginid_details = $user->loginid_details;

        foreach my $account (keys $loginid_details->%*) {

            next unless ($loginid_details->{$account}{platform} // '') eq 'mt5' && ($loginid_details->{$account}{account_type} // '') eq 'real';

            if ($loginid_details->{$account}{attributes}{group} =~ m{$jurisdiction}) {
                push @mt5_accounts, $account;
            }
        }

        return @mt5_accounts;
    }

=head2 status_transition

Transit and log the status from one to another

=over 4

=item * C<$params> Hashref that contains binary_user_id, loginid, from_status, to_status fields

=back

Returns 1 if succeed, hashref with error field otherwise

=cut

    method status_transition ($params) {
        return $self->return_error("status_transition", "No parameters passed") unless ($params);

        my $loginid     = $params->{loginid};
        my $from_status = $params->{status}    // 'none';
        my $to_status   = $params->{to_status} // 'none';

        return 1 if ($from_status eq $to_status);
        try {
            $self->update_loginid_status($params);
            $self->dd_log_info("status_transition", "Client $loginid status transition from $from_status to $to_status");
            return 1;
        } catch ($e) {
            return $self->return_error("status_transition", "Failed on status transition for $loginid from $from_status to $to_status: $e")
        }
    }

=head2 withdraw_and_archive

Withdraws the balance of the MT5 client to his CR account, archives the MT5 account

It gets the currency of the group and of the cr accounts, converts currency if needed,
withdraws the balance of the MTR account, transfers them to a CR account and records the payment 

=over 4

=item * C<$params> Hashref that contains binary_user_id, loginid, cr_currency, group, user, client fields

=back

Returns a hashref with result => 1 if succeed, hashref with error field otherwise

=cut

    async method withdraw_and_archive($params) {
        return $self->return_error("withdraw_and_archive", "No parameters passed") unless ($params);

        my $loginid        = $params->{loginid};
        my $cr_currency    = $params->{cr_currency};
        my $group          = $params->{group};
        my $client         = $params->{client};
        my $bom_loginid    = $params->{bom_loginid};
        my $binary_user_id = $params->{binary_user_id};

        try {
            # Get user to check balance
            my $mt_user = await BOM::MT5::User::Async::get_user($loginid);

            # Check balance and withdraw
            if ($mt_user->{balance} and $mt_user->{balance} > 0) {

                $self->dd_log_info('withdraw_and_archive', "Withdrawing and archiving $loginid");

                my $group_currency = await BOM::MT5::User::Async::get_group($group);
                $group_currency = $group_currency->{currency};

                my $transfer_amount =
                    $group_currency ne $cr_currency
                    ? convert_currency($mt_user->{balance}, $group_currency, $cr_currency)
                    : $mt_user->{balance};

                $transfer_amount = financialrounding('price', $cr_currency, $transfer_amount);

                my $withdraw_response = await BOM::MT5::User::Async::withdrawal({
                    login   => $loginid,
                    amount  => $mt_user->{balance},
                    comment => $loginid . '_' . $bom_loginid,
                });

                $self->dd_log_info('withdraw_and_archive', "Withdraw for $loginid successful");
                if ($withdraw_response->{status}) {

                    my ($txn) = $client->payment_mt5_transfer(

                        currency => $cr_currency,
                        amount   => $transfer_amount,
                        remark   => "Transfer from MT5 account "
                            . $loginid . " to "
                            . $bom_loginid . " "
                            . $cr_currency
                            . $mt_user->{balance} . " to "
                            . $group_currency
                            . $transfer_amount,
                        staff  => 'quant',
                        fees   => 0,
                        source => 1

                    );

                    my $storing_payment_result = $self->record_mt5_transfer({
                        dbic           => $client->db->dbic,
                        payment_id     => $txn->payment_id,
                        mt5_amount     => $mt_user->{balance},
                        mt5_account_id => $loginid,
                        mt5_currency   => $group_currency
                    });

                    if ($storing_payment_result->{result}) {
                        $self->dd_log_info(
                            "withdraw_and_archive",
                            sprintf(
                                "[%s] Transfer from MT5 login: %s to binary account %s %s %s",
                                Time::Moment->now, $loginid, $bom_loginid, $group_currency, $mt_user->{balance}));
                    }

                } else {
                    return $self->return_error("withdraw_and_archive", "The script ran into an error while withdrawing poa_failed client $loginid");
                }

            }

            # Archive client
            my $archive_response = await BOM::MT5::User::Async::user_archive($loginid);
            return $self->return_error("withdraw_and_archive", "Failed to archive $loginid client")
                unless ($archive_response->{status});

            $self->dd_log_info("withdraw_and_archive",
                "Client $loginid is archived due to poa verification failed and " . DISABLE_ACCOUNT_DAYS . " days of inactivity");

            $self->update_loginid_status({binary_user_id => $binary_user_id, loginid => $loginid, to_status => 'archived'});
            $self->dd_log_info('withdraw_and_archive', "Archived $loginid");

            return {result => 1};

        } catch ($e) {
            return $self->return_error("withdraw_and_archive",
                "The script ran into an error while withdrawing and archiving poa_failed client $loginid: $e");
        }

    }

=head2 check_activity_and_process_client

Checks for open orders and open positions and proceeds to withdraw balance and archive the MT5 client
In case of open order or positions no action on the account is made, the loginid and the group of these accounts 
will be sent to compops via email

=over 4

=item * C<$params> Hashref that contains binary_user_id, loginid, cr_currency, group, user, client fields

=back

Returns a hashref with send_to_compops => 1 in case of open orders or positions,
or hashref with the status of the withdraw_and_archive
or error field otherwise

=cut

    async method check_activity_and_process_client($params) {
        return $self->return_error("check_activity_and_process_client", "No parameters passed") unless ($params);

        my $loginid = $params->{loginid};
        try {
            my $open_orders    = await BOM::MT5::User::Async::get_open_orders_count($loginid);
            my $open_positions = await BOM::MT5::User::Async::get_open_positions_count($loginid);

            if ($open_orders->{total} or $open_positions->{total}) {
                $self->dd_log_info('check_activity_and_process_client', "Client $loginid has open orders or positions, sending to x-compops");
                return +{send_to_compops => 1};
            } else {
                return await $self->withdraw_and_archive($params);
            }
        } catch ($e) {
            return $self->return_error("check_activity_and_process_client",
                "The script ran into an error while checking activity of a poa_failed client $loginid:" . pp($e));
        }
        return +{};

    }

=head2 restrict_client_and_send_email

Sets MT5 account color to RED, change status to poa_failed, send email informing about the restriction of trading rights
If one of the accounts failed to get restricted, the sub will try again several times, if still fails the email will not be sent
and the error will be logged

=over 4

=item * C<$params> Hashref that contains binary_user_id, loginid, cr_currency, group, user, client fields

=back

Returns a hashref with send_to_compops => 1 in case of open orders or positions,
or hashref with the status of the withdraw_and_archive
or error field otherwise

=cut

    method restrict_client_and_send_email ($params) {
        return $self->return_error("restrict_client_and_send_email", "No parameters passed") unless ($params);

        my $group       = $params->{group};
        my $bom_loginid = $params->{bom_loginid};

        my $landing_company = ($group =~ m{bvi} ? 'bvi' : ($group =~ m{vanuatu} ? 'vanuatu' : ''));
        my @mt5_accounts_under_same_jurisdiction =
            $self->get_mt5_accounts_under_same_jurisdiction({jurisdiction => $landing_company, user => $params->{user}});
        $self->dd_log_info('restrict_client_and_send_email',
            "Client $bom_loginid has " . pp(@mt5_accounts_under_same_jurisdiction) . " under the $landing_company jurisdiction");

        my $jurisdiction_restricted = 1;
        my $account_restricted      = 0;

        for my $mt5_account (@mt5_accounts_under_same_jurisdiction) {

            next if $parsed_mt5_account{$mt5_account};
            my $tries          = 0;
            my $color_changed  = 0;
            my $status_updated = 0;
            while (not $account_restricted and $tries++ < RETRY_LIMIT) {
                try {

                    $color_changed = $self->change_color_to_red($mt5_account) unless ($color_changed);
                    $self->return_error("restrict_client_and_send_email",
                        "Failed to change color for $mt5_account" . (($tries < RETRY_LIMIT) ? '. Trying again' : '.'))
                        unless ($color_changed);

                    $status_updated = $self->update_loginid_status({%$params, to_status => 'poa_failed'}) unless ($status_updated);
                    $self->return_error("restrict_client_and_send_email",
                        "Failed to change status for $mt5_account" . (($tries < RETRY_LIMIT) ? '. Trying again' : '.'))
                        unless ($status_updated);

                    if ($color_changed and $status_updated) {

                        $self->dd_log_info("restrict_client_and_send_email",
                            "Client $mt5_account is restricted for $landing_company groups due to poa submit expiry")
                            if $self->send_email_to_client({
                                email_type   => 'poa_verification_expired',
                                email_params => {
                                    loginid     => $bom_loginid,
                                    mt5_account => $mt5_account
                                }});
                    } else {
                        $self->return_error("restrict_client_and_send_email", "The account $mt5_account is restricted but failed to send the email");
                    }

                    $account_restricted = $color_changed && $status_updated;
                } catch ($e) {
                    $self->return_error("restrict_client_and_send_email",
                        "The script ran into an error while changing color and updating status for poa pending/rejected client $mt5_account: $e");
                }
            }

            $parsed_mt5_account{$mt5_account} = 1;
            # if one of the accounts failed to get restricted, don't send the restriction email to not spam
            $jurisdiction_restricted &&= $account_restricted;
        }

        if ($jurisdiction_restricted) {
            return 1;
        } else {
            $self->return_error("restrict_client_and_send_email", "The user $bom_loginid is not restricted due to a fail, email not send");
        }
        return 0;
    }

=head2 return_error

Logs the error in DataDog and returns error field in a hashref

=over 4

=item * C<$method> String representing the method in which error ocurred

=item * C<$error_message> String with the description of the failure

=back

Returns a hashref with error field with the description of the failure

=cut

    method return_error ($method, $error_message) {
        stats_event("StatusUpdate.$method", "Error: $error_message", {alert_type => 'error'});
        return {error => 1};
    }

=head2 dd_log_info

Logs info in DataDog

=over 4

=item * C<$method> String representing the method that logs info

=item * C<$error_message> String with the description of the failure

=back

Does not return any value

=cut

    method dd_log_info ($method, $info) {
        stats_event("StatusUpdate.$method", "Info: $info", {alert_type => 'info'});
        return;
    }

=head2 gather_users

Makes a sql query to gather accounts with a certain status with their 
creation stamp starting from a certain day

=over 4

=item * C<$params> Hashref with oldest_created_at, newest_created_at, statuses

=item * C<$statuses> Arrayref with the statuses in form of ['poa_pending', 'poa_rejected']

=back

Returns an Array, filled with Arrayrefs for every account gathered from db

=cut

    method gather_users ($params) {
        my $oldest_created_at = $params->{oldest_created_at};
        my $newest_created_at = $params->{newest_created_at};
        my $statuses          = $params->{statuses};
        return $self->return_error("gather_users", "The newest_created_at and statuses fields are required for this operation")
            unless ($newest_created_at and $statuses);

        my $retries     = 0;
        my $users_batch = [];
        my $users       = [];

        do {
            try {
                $users_batch = $userdb->dbic->run(
                    fixup => sub {
                        $_->selectall_arrayref(
                            'select * from users.get_loginids_poa_timeframe(?, ?, ?::users.loginid_status[], ?)',
                            undef,
                            ($oldest_created_at ? $oldest_created_at->truncate_to_day->db_timestamp : undef),
                            (@$users            ? $users->[-1]->[2] : $newest_created_at->plus_time_interval('1d')->truncate_to_day->db_timestamp),
                            $statuses,
                            ACCOUNTS_BATCH_SIZE
                        );
                    }) || [];

                push @$users, @$users_batch;
                $retries = 0;

            } catch ($e) {
                $self->return_error('gather_users', 'Failed to gather users: ' . pp $e);
                $retries++;
                $self->dd_log_info('gather_users', 'Retrying to gather users');
            }

        } while (@$users_batch >= ACCOUNTS_BATCH_SIZE or ($retries > 0 and $retries < RETRY_LIMIT));

        return @$users;

    }

=head2 grace_period_actions

Gathers clients with poa pending and rejected statuses within a certain period of creation, restricts and warns them
to submit a poa verification

Does not takes or returns any parameters

=cut

    method grace_period_actions {

        my @combined = $self->gather_users({
            newest_created_at => $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_WARNING_DAYS) . 'd'),
            statuses          => ['poa_pending', 'poa_rejected', 'poa_outdated'],
        });

        $self->dd_log_info('grace_period_actions',
                  "Gathered "
                . scalar(@combined)
                . " accounts form the DB with status ['poa_pending', 'poa_rejected', 'poa_outdated'] with the newest created at: "
                . $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_WARNING_DAYS) . 'd')->datetime_ddmmmyy_hhmmss_TZ);

        my $loginid;

        foreach my $data (@combined) {
            try {

                my $mt5_client = $self->parse_user($data);
                next if ($mt5_client->{error});
                my $binary_user_id = $mt5_client->{binary_user_id};

                next if $parsed_binary_user_id{$binary_user_id};

                $loginid = $mt5_client->{loginid} // 'undef';
                my $group          = $mt5_client->{group};
                my $creation_stamp = $mt5_client->{creation_stamp};

                my $user_data = $self->load_all_user_data($binary_user_id);
                my $client    = $user_data->{client};

                if ($client->get_poa_status eq 'verified') {
                    $mt5_client->{to_status} = undef;
                    $self->update_loginid_status($mt5_client);
                    $self->dd_log_info("grace_period_actions",
                        "The client with loginid $loginid status is updated to clear, because his prove of address status is verified");
                    next;
                }

                if (   ($group =~ m{bvi} and $creation_stamp->days_since_epoch < $bvi_expiration_timestamp->days_since_epoch)
                    or ($group =~ m{vanuatu} and $creation_stamp->days_since_epoch < $vanuatu_expiration_timestamp->days_since_epoch))
                {
                    $parsed_binary_user_id{$binary_user_id} = 1 if ($self->restrict_client_and_send_email({%$mt5_client, %$user_data}));
                }

            } catch ($e) {
                $self->return_error("grace_period_actions",
                    "The script ran into an error while checking/updating status for poa pending/rejected client $loginid: $e");
            }
        }
    }

=head2 disable_users_actions

Gathers clients with poa failed status within a certain period of creation, disables, archives and transfers their MTR
balance to CR account and warns them about it via email
Sends a reports to compops about the MTR accounts that have open orders or positions

Does not takes or returns any parameters

=cut

    method disable_users_actions {
        my @bvi_clients_to_compops;
        my @vanuatu_clients_to_compops;

        my @combined = $self->gather_users({
            newest_created_at => $now->minus_time_interval(DISABLE_ACCOUNT_DAYS . 'd'),
            statuses          => ['poa_failed'],
        });

        $self->dd_log_info('disable_users_actions',
                  "Gathered "
                . scalar(@combined)
                . " accounts form the DB with status ['poa_failed'] with the newest created at: "
                . $now->minus_time_interval(DISABLE_ACCOUNT_DAYS . 'd')->datetime_ddmmmyy_hhmmss_TZ);

        my $loginid;

        foreach my $data (@combined) {
            try {

                my $mt5_client = $self->parse_user($data);
                $self->dd_log_info('disable_users_actions', 'Parsed client: ' . pp($mt5_client));

                next if ($mt5_client->{error});
                $loginid = $mt5_client->{loginid} // 'undef';
                my $creation_stamp = $mt5_client->{creation_stamp};

                my $user_data = $self->load_all_user_data($mt5_client->{binary_user_id});
                my $group     = $mt5_client->{group};

                if ($group =~ m/(bvi|vanuatu)/) {
                    my $expiration_days = $1 eq 'bvi' ? BVI_EXPIRATION_DAYS : VANUATU_EXPIRATION_DAYS;

                    if ($creation_stamp->days_since_epoch + $expiration_days + DISABLE_ACCOUNT_DAYS <= $now->days_since_epoch) {
                        if (not defined $user_data->{client}
                            or $self->check_activity_and_process_client({%$mt5_client, %$user_data})->get->{send_to_compops})
                        {
                            my $client_info = "<tr><td>$loginid</td><td>$group</td></tr>";

                            if ($1 eq 'bvi') {
                                push @bvi_clients_to_compops, $client_info;
                            } else {
                                push @vanuatu_clients_to_compops, $client_info;
                            }
                        }
                    }
                }

            } catch ($e) {
                $self->return_error("disable_users_actions", "The script ran into an error while processing poa failed client $loginid: $e");
            }
        }

        my @lines;

        if (scalar(@bvi_clients_to_compops)) {
            push @lines, "<p>Active MT5 BVI clients with poa failed:<p>", '<table border=1>';
            push @lines, '<tr><th>Loginid</th><th>Group</th></tr>';
            push(@lines, @bvi_clients_to_compops);
            push @lines, '</table>';
        }

        if (scalar(@vanuatu_clients_to_compops)) {
            push @lines, "<p>Active MT5 Vanuatu clients with poa failed:<p>", '<table border=1>';
            push @lines, '<tr><th>Loginid</th><th>Group</th></tr>';
            push(@lines, @vanuatu_clients_to_compops);
            push @lines, '</table>';
        }

        if (scalar(@lines)) {
            $self->dd_log_info('disable_users_actions',
                      "Sending "
                    . scalar(@bvi_clients_to_compops)
                    . " bvi clients and "
                    . scalar(@vanuatu_clients_to_compops)
                    . " vanuatu clients to x-compops");

            my $brand = Brands->new();
            BOM::Platform::Event::Emitter::emit(
                'send_email',
                {
                    from                  => $brand->emails('system'),
                    to                    => $brand->emails('compliance_ops'),
                    subject               => 'CRON update_mt5_trading_rights_and_status: Report for ' . $now->date,
                    email_content_is_html => 1,
                    message               => \@lines,
                });
        }

    }

=head2 sync_status_actions

Gathers clients with poa_failed, poa_rejected, proof_failed and verification_pending statuses within a certain period of creation,
checks their latest POI and POA status and updates user.loginid table with the appropreate status as in the following table

#-------------------------------------------------------------------------------#
#                       States transition table                                 #
#-------------------------------------------------------------------------------#
# POI           POA		            Status                                      #
#-------------------------------------------------------------------------------#
# pending       pending		        verification_pending                        #
# pending		''                  verification_pending (within grace period)  #
# pending	    failed		        poa_failed (exceeded grace period)          #
# pending	    successful		    verification_pending                        #
# failed	    pending		        proof_failed                                #
# failed	    failed		        proof_failed                                #
# failed	    successful		    proof_failed                                #
# successful	pending		        poa_pending                                 #
# successful	failed		        poa_failed                                  #
# successful	expired 		    poa_outdated                                #
# successful	successful		    ''                                          #
#-------------------------------------------------------------------------------#

Does not takes or returns any parameters

=cut

    method sync_status_actions {
        my @combined = $self->gather_users({
            newest_created_at => $now,
            statuses          => ['poa_failed', 'proof_failed', 'verification_pending', 'poa_rejected', 'poa_pending', 'poa_outdated'],
        });

        $self->dd_log_info('sync_status_actions',
                  "Gathered "
                . scalar(@combined)
                . " accounts form the DB with status ['poa_failed', 'proof_failed', 'verification_pending', 'poa_rejected', 'poa_pending'] with the newest created at: "
                . $now->datetime_ddmmmyy_hhmmss_TZ);

        my %processed_binary_user;
        foreach my $data (@combined) {
            my $mt5_client = $self->parse_user($data);
            next if ($mt5_client->{error});
            my $binary_user_id = $mt5_client->{binary_user_id};
            next if $processed_binary_user{$binary_user_id};

            my $user_data = $self->load_all_user_data($binary_user_id);
            my $client    = $user_data->{client};

            unless ($processed_binary_user{$binary_user_id}) {
                BOM::Platform::Event::Emitter::emit(
                    'sync_mt5_accounts_status',
                    {
                        binary_user_id => $client->binary_user_id,
                        client_loginid => $client->loginid
                    });

                $processed_binary_user{$binary_user_id} = 1;
            }
        }

    }

=head2 send_reminder_emails

Gathers clients with poa_failed, poa_rejected statuses within a certain period of creation,
sends them email reminders to resubmit POA

Does not takes or returns any parameters

=cut

    method send_reminder_emails {

        my @combined = $self->gather_users({
            newest_created_at => $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_EXPIRATION_DAYS) + FIRST_REMINDER_EMAIL_DAYS . 'd'),
            statuses          => ['poa_failed', 'poa_rejected'],
        });

        $self->dd_log_info('send_reminder_emails',
                  "Gathered "
                . scalar(@combined)
                . " accounts form the DB with status ['poa_failed', 'poa_rejected'] with the newest created at: "
                . $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_EXPIRATION_DAYS) + FIRST_REMINDER_EMAIL_DAYS . 'd')
                ->datetime_ddmmmyy_hhmmss_TZ);

        my $error_ocurred = 0;
        my $bom_loginid;

        foreach my $data (@combined) {
            try {

                my $mt5_client = $self->parse_user($data);
                next if ($mt5_client->{error});

                my $user_data      = $self->load_all_user_data($mt5_client->{binary_user_id});
                my $group          = $mt5_client->{group};
                my $creation_stamp = $mt5_client->{creation_stamp};
                my $loginid        = $mt5_client->{loginid};
                $bom_loginid = $user_data->{bom_loginid};

                if ($group =~ m{bvi}) {
                    if (   ($creation_stamp->days_since_epoch == $bvi_expiration_timestamp->days_since_epoch - FIRST_REMINDER_EMAIL_DAYS)
                        or ($creation_stamp->days_since_epoch == $bvi_expiration_timestamp->days_since_epoch - SECOND_REMINDER_EMAIL_DAYS))
                    {

                        $self->send_email_to_client({
                                email_type   => 'poa_verification_failed_reminder',
                                email_params => {
                                    loginid        => $bom_loginid,
                                    mt5_account    => $loginid,
                                    disabling_date => $creation_stamp->plus_time_interval((BVI_EXPIRATION_DAYS + DISABLE_ACCOUNT_DAYS) . 'd')->date
                                }});

                    }
                } elsif ($group =~ m{vanuatu}) {
                    if (   ($creation_stamp->days_since_epoch == $vanuatu_expiration_timestamp->days_since_epoch - FIRST_REMINDER_EMAIL_DAYS)
                        or ($creation_stamp->days_since_epoch == $vanuatu_expiration_timestamp->days_since_epoch - SECOND_REMINDER_EMAIL_DAYS))
                    {

                        $self->send_email_to_client({
                                email_type   => 'poa_verification_failed_reminder',
                                email_params => {
                                    loginid        => $bom_loginid,
                                    mt5_account    => $loginid,
                                    disabling_date =>
                                        $creation_stamp->plus_time_interval((VANUATU_EXPIRATION_DAYS + DISABLE_ACCOUNT_DAYS) . 'd')->date
                                }});

                    }
                }
            } catch ($e) {
                $self->return_error("send_reminder_emails", "The script ran into an error while processing poa_failed client $bom_loginid: $e");
                $error_ocurred = 1;
            }
        }

        return $self->return_error("send_reminder_emails",
            "There have been some errors while sending reminder emails for poa_failed clients, check logs")
            if ($error_ocurred);
    }

=head2 send_warning_emails

Gathers clients with poa_pending statuse within a certain period of creation,
sends them email informing them that the account will be restricted if thei don't
submit a POA untill a certain date

Does not takes or returns any parameters

=cut

    method send_warning_emails {

        my @combined = $self->gather_users({
            newest_created_at => $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_WARNING_DAYS) . 'd'),
            statuses          => ['poa_pending'],
        });

        $self->dd_log_info('send_warning_emails',
                  "Gathered "
                . scalar(@combined)
                . " accounts form the DB with status ['poa_pending'] with the newest created at: "
                . $now->minus_time_interval(min(BVI_WARNING_DAYS, VANUATU_WARNING_DAYS) . 'd')->datetime_ddmmmyy_hhmmss_TZ);

        my $loginid;
        foreach my $data (@combined) {
            try {

                my $mt5_client = $self->parse_user($data);
                next if ($mt5_client->{error});
                my $binary_user_id = $mt5_client->{binary_user_id};
                $loginid = $mt5_client->{loginid};

                my $creation_stamp = $mt5_client->{creation_stamp};
                my $user_data      = $self->load_all_user_data($binary_user_id);
                my $group          = $mt5_client->{group};
                my $bom_loginid    = $user_data->{bom_loginid};
                my $client         = $user_data->{client};

                if ($client->get_poa_status eq 'verified') {

                    $self->update_loginid_status($mt5_client);
                    $self->dd_log_info("send_warning_emails",
                        "The client with loginid $loginid status is updated to clear, because his prove of address status is verified");
                    next;
                }

                if ($group =~ m{bvi} and $creation_stamp->days_since_epoch == $bvi_warning_timestamp->days_since_epoch) {

                    my $poa_expiry_date = $creation_stamp->plus_time_interval(BVI_EXPIRATION_DAYS . 'd');
                    $self->send_email_to_client({
                            email_type   => 'poa_verification_warning',
                            email_params => {
                                loginid         => $bom_loginid,
                                poa_expiry_date => $poa_expiry_date->date,
                                mt5_account     => $loginid
                            }});

                } elsif ($group =~ m{vanuatu} and $creation_stamp->days_since_epoch == $vanuatu_warning_timestamp->days_since_epoch) {

                    my $poa_expiry_date = $creation_stamp->plus_time_interval(VANUATU_EXPIRATION_DAYS . 'd');

                    $self->send_email_to_client({
                            email_type   => 'poa_verification_warning',
                            email_params => {
                                loginid         => $bom_loginid,
                                poa_expiry_date => $poa_expiry_date->date,
                                mt5_account     => $loginid
                            }});

                }
            } catch ($e) {
                $self->return_error("send_warning_emails", "The script ran into an error while processing client $loginid: $e");
            }
        }
    }

=head2 check_poa_issuance

It checks the `users.poa_issuance` table for outdated POAs (1 year after issuance date).

Set the status of the MT5 accounts as `poa_outdated` on outdated POAs scenario.

=cut

    method check_poa_issuance {
        my $boundary = BOM::User::Client::AuthenticationDocuments::Config::outdated_boundary('POA');

        return undef unless $boundary;

        my $mt5_config   = BOM::Config::MT5->new;
        my $reg_accounts = [uniq map { $mt5_config->available_groups({company => $_, server_type => 'real'}, 1) } qw/bvi labuan vanuatu/];

        $userdb->dbic->run(
            fixup => sub {
                $_->do('SELECT users.update_outdated_poa_mt5_loginids(?::DATE,?::VARCHAR[])', undef, $boundary->date_yyyymmdd, $reg_accounts);
            });
    }
}

1;
