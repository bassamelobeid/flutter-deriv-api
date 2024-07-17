package BOM::Event::Actions::MT5TechnicalAccounts;

use strict;
use warnings;
use Log::Any qw($log);
use Future::AsyncAwait;
use Syntax::Keyword::Try;
use BOM::MT5::User::Async;
use BOM::Config;
use BOM::User;
use Digest::SHA qw(sha384_hex);
use BOM::Database::UserDB;
use Time::Moment;
use Pod::Usage;
use Deriv::TradingPlatform::MT5::UserRights qw(get_value);
use BOM::Platform::Email                    qw(send_email);
use DataDog::DogStatsd::Helper              qw(stats_event);

=head1 NAME 

BOM::Event::Actions::MT5TechnicalAccounts - Module for creating technical accounts on MT5 platform.

=head1 SYNOPSIS 

use BOM::Event::Actions::MT5TechnicalAccounts;

=head1 DESCRIPTION 

This module provides functionality for creating technical accounts on the MetaTrader 5 (MT5) platform for the given MT5 IB Main Agent Account

Technical accounts are essential for commission transfers across servers.

Features include:

- Creating new technical accounts on the MT5 platform.
- Inserting the MT5 Technical Account details into the user database.

=cut

my $servers = _prepare_server_configs();
our $group_to_ccy = {};
our %my_servers   = %$servers;
my %tech_defaults = (
    group          => "real\\%s\\synthetic\\svg_ibt_%s",    # %s will be replaced by each trade server key and main account's group currency
    rights         => "EnUsersRights::USER_RIGHT_NONE",     # 0x0000000000000000
    comment        => "%s",                                 # will be replaced by main mt5 account id
    mainPassword   => "%s",                                 # will be replaced with password generation
    investPassword => "%s",                                 # will be replaced with password generation
    leverage       => '1:100',
);

=head2 create_mt5_ib_technical_accounts

Creates MT5 Introducing Broker (IB) technical accounts.

This subroutine is responsible for creating technical accounts for IBs based on their main MT5 account. 
It checks for existing accounts on different servers, creates new technical accounts where necessary, and updates the database accordingly.

Returns:
    - Nothing explicitly, but it updates the database and sends notifications based on the process outcomes.

Example:
    await create_mt5_ib_technical_accounts({
        mt5_account_id => 'MTR123456',
        binary_user_id => '123',
        provider       => 'dynamicworks',
        partner_id     => 'CU1234567'
    });

=cut

async sub create_mt5_ib_technical_accounts {
    my $args = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my ($mt5_id_with_prefix, $binary_user_id, $provider, $partner_id) = @{$args}{qw/mt5_account_id binary_user_id provider partner_id/};

    my $mt5_user_data;
    my $main_account_currency;
    my $user_information;
    my %notifs;

    try {
        $mt5_user_data = await _get_main_mt5_account($mt5_id_with_prefix);
        if ($mt5_user_data->{error}) {
            die $mt5_user_data->{error};
        }
        $main_account_currency = $mt5_user_data->{currency};
        $user_information      = $mt5_user_data->{data};
    } catch ($err) {
        $log->errorf("Failed to get main MT5 account: %s", $err);
        _add_to_notifications(\%notifs, 'Failed', $err, 'Main', 'N/A', $mt5_id_with_prefix, $binary_user_id, $partner_id);
        _send_email_to_marketing_team(\%notifs);
        return;
    }

    for my $server (sort keys %my_servers) {
        my $mt5_account_id;

        my $main_server  = _get_mt5_server_name($mt5_id_with_prefix);
        my %mt5_accounts = _get_accounts_from_database($partner_id);

        try {
            if (defined $mt5_accounts{$server} && $mt5_accounts{$server}) {
                if ($server ne $main_server) {
                    try {
                        await BOM::MT5::User::Async::get_user("MTR" . $mt5_accounts{$server});
                        _add_to_notifications(\%notifs, 'Failed', 'Technical account already exists in a valid shape on this server.',
                            'Technical', $server, $mt5_accounts{$server}, $binary_user_id, $partner_id);
                    } catch ($err) {
                        _add_to_notifications(\%notifs, 'Failed', 'Exists in DB, not on MT5; Might be archived',
                            'Technical', $server, $mt5_accounts{$server}, $binary_user_id, $partner_id);
                    }
                } else {
                    _add_to_notifications(\%notifs, 'Failed', 'Main MT5 account already exists in affiliate table',
                        'Main', $server, $mt5_id_with_prefix, $binary_user_id, $partner_id);
                }
                next;
            }

            if ($server eq $main_server) {
                $mt5_account_id = $mt5_id_with_prefix;
                _add_to_notifications(\%notifs, 'Success', undef, 'Main', $server, $mt5_account_id, $binary_user_id, $partner_id);
            } else {
                $user_information = _prepare_mt5_accounts_info($server, $user_information, $main_account_currency, $mt5_id_with_prefix);
                try {
                    die 'Group is undefined' unless $user_information->{group};
                    my $tech_acc = await BOM::MT5::User::Async::create_user($user_information);
                    $mt5_account_id = $tech_acc->{login};
                    _add_to_notifications(\%notifs, 'Success', undef, 'Technical', $server, $mt5_account_id, $binary_user_id, $partner_id);
                } catch ($err) {
                    _add_to_notifications(\%notifs, 'Failed', $err, 'Technical', $server, $mt5_id_with_prefix, $binary_user_id, $partner_id);
                }
            }

            my $account_type = $server eq $main_server ? 'main' : 'technical';
            my %key_formats  = _parse_server_key($server);
            $mt5_account_id =~ s/\D//g;
            my ($added) = $dbic->run(
                ping => sub {
                    $_->selectrow_array(q{SELECT * FROM mt5.add_partner_account(?, ?, ?, ?, ?, ?)},
                        undef, $key_formats{old}, $mt5_account_id, $partner_id, $binary_user_id, $account_type, $key_formats{new});
                });

            if (!$added) {
                _add_to_notifications(\%notifs, 'Failed', 'DB insertion failed',
                    $account_type, $server, $mt5_account_id, $binary_user_id, $partner_id);
            }
        } catch ($err) {
            $log->errorf("\t\t[X] %s", $err);
            _add_to_notifications(\%notifs, 'Failed', $err, 'Technical', $server, $mt5_id_with_prefix, $binary_user_id, $partner_id);
            stats_event(
                'IB Tech Account Creation',
                "Failed to create IB tech account for affiliate $partner_id on server $server: $err",
                {alert_type => 'error'});
        }
    }

    _send_email_to_marketing_team(\%notifs);
}

=head2 _get_main_mt5_account

Retrieves the main MT5 account information and currency.

This private subroutine fetches the main MT5 account's details, including the account's currency, based on the provided MT5 account ID. 
It handles cases where the account might be archived and attempts to unarchive it if necessary.

Returns:
    A hash reference containing the main MT5 account's details.
    If the account cannot be retrieved or another error occurs, the subroutine will die with an appropriate error message.

Example:
    my $account_info = await _get_main_mt5_account('MTR123456');

=cut

async sub _get_main_mt5_account {
    my ($mt5_id_with_prefix) = @_;
    my $main_server          = _get_mt5_server_name($mt5_id_with_prefix);
    my $result               = {};

    try {
        my $user;

        try {
            $user = await BOM::MT5::User::Async::get_user($mt5_id_with_prefix);
        } catch ($e) {
            if (ref $e eq 'HASH' and $e->{code} eq 'NotFound') {
                my $unarchive_result = await _unarchive_main_account($main_server, $mt5_id_with_prefix);
                die "get_user_error: unable to unarchive user" unless $unarchive_result;
                $user = await BOM::MT5::User::Async::get_user($mt5_id_with_prefix);
            } else {
                die "get_user_error: $e";
            }
        }

        die "undefined_group_error: IB tech account creation failed due to undefined group for MT5 account ID" unless $user->{group};

        if (not defined $group_to_ccy->{$user->{group}}) {
            try {
                my $user_group = await BOM::MT5::User::Async::get_group($user->{group});
                $group_to_ccy->{$user->{group}} = $user_group->{currency};
            } catch ($err) {
                $log->errorf("\t[X] Could not get user's group description to find the currency, group %s", $user->{group});
                die "get_group_error: $err";
            }
        }

        my $currency = $group_to_ccy->{$user->{group}};
        die 'get_currency_error: unable to fetch currency' unless defined $currency;

        $result->{data} = {
            state         => $user->{state},
            phonePassword => $user->{phonePassword},
            phone         => $user->{phone},
            group         => $user->{group},
            country       => $user->{country},
            city          => $user->{city},
            agent         => $user->{agent},
            color         => $user->{color},
            balance       => $user->{balance},
            comment       => $user->{comment},
            leverage      => $user->{leverage},
            zipCode       => $user->{zipCode},
            rights        => $user->{rights},
            email         => $user->{email},
            name          => $user->{name},
            address       => $user->{address},
            company       => $user->{company},
        };
        $result->{currency} = lc $currency;

        my $market_type = BOM::Config::MT5->new()->get_market_type_from_group($user->{group});
        die "unrecognized_group_error: IB tech account creation failed due to unrecognized group format"
            unless defined $market_type;

        if ($market_type eq "financial") {
            die "financial_group_error: IB Tech account creation disabled for MT5 account in financial or financial stp group";
        }

        my $comment_added = await _add_ib_comment($mt5_id_with_prefix, $user);
        die "comment_error: IB comment already exists for this main account. Please check again." unless $comment_added;

    } catch ($err) {
        $log->errorf("Error encountered while fetching details for main mt5 account: %s", $err);
        return {
            error => $err,
            data  => {},
        };
    }

    return $result;
}

=head2 _add_ib_comment

This asynchronous subroutine updates the comment field of a user's MT5 account to 'IB', indicating that the user is an Introducing Broker. 
It does not update the comment if it is already set to 'IB'.

Returns:
    - 1 on success, indicating the user's comment was updated.
    - 0 if the user's comment is already 'IB', indicating no update was necessary.

Example:
    my $result = await _add_ib_comment('MTR123456', $user);

=cut

async sub _add_ib_comment {
    my ($mt5_id_with_prefix, $user) = @_;

    return 0 if $user->{comment} =~ /^IB$/;
    $user->{comment} = 'IB';
    await BOM::MT5::User::Async::update_user($user);

    return 1;
}

=head2 _unarchive_main_account

Attempts to unarchive a main MT5 account and update its trading rights.

This asynchronous subroutine tries to unarchive a previously archived MT5 account. 
It retrieves the account from the archive, restores it, and updates its trading rights to 'enabled'. 

Returns:
    - 1 on successful unarchiving and updating of the account.
    - 0 if the operation fails at any point.

Example:
    my $success = await _unarchive_main_account('p01_ts03', 'MTR123456');

=cut

async sub _unarchive_main_account {
    my ($main_server, $mt5_id_with_prefix) = @_;

    my $succeed = 0;

    try {
        my $archived_user = await BOM::MT5::User::Async::get_user_archive($mt5_id_with_prefix);

        die "Undefined user object for account while unarchiving" unless $archived_user and $archived_user->{login};
        await BOM::MT5::User::Async::user_restore($archived_user);

        # Update MT5 trading rights
        await BOM::MT5::User::Async::update_user({
            login  => $mt5_id_with_prefix,
            rights => Deriv::TradingPlatform::MT5::UserRights::get_value(qw(enabled)),
        });

        my $user = BOM::User->new(loginid => $mt5_id_with_prefix);

        $user->update_loginid_status($mt5_id_with_prefix, undef);

        if ($archived_user->{balance} > 0) {
            # After restoring account, there is a balance check and fix process to apply the balance amount to the recently restored account
            await BOM::MT5::User::Async::user_balance_check($mt5_id_with_prefix);
        }

        $succeed = 1;
    } catch ($err) {
        $log->errorf("\t\t[X] unable to unarchive account: %s", $err);
    }

    return $succeed;
}

=head2 _get_mt5_server_name

Determines the MT5 server name based on the account ID.

Example:
    my $server_name = _get_mt5_server_name('MTR123456');

=cut

sub _get_mt5_server_name {
    my ($mt5_account_id) = @_;
    $mt5_account_id =~ s/^MTR//;

    for my $server (keys %my_servers) {
        for my $range ($my_servers{$server}->{ranges}->@*) {
            return $server if $mt5_account_id >= $range->{from} and $mt5_account_id <= $range->{to};
        }
    }

    $log->errorf("\t\t[X] No matching server for mt5 loginid in config file!");
    return undef;
}

=head2 _prepare_server_configs

This subroutine extracts MT5 server information and prepares a hash of server configurations. 

=cut

sub _prepare_server_configs {
    my $config;
    my $result = {};
    my $mt5_http_proxy_url;

    try {
        $config = BOM::Config::mt5_webapi_config();

        if (defined $config->{real}) {
            $mt5_http_proxy_url = $config->{mt5_http_proxy_url};
            for my $server (keys $config->{real}->%*) {
                next
                    if not defined $config->{real}{$server}{server}
                    or not defined $config->{real}{$server}{manager}
                    or not defined $config->{real}{$server}{accounts}
                    or scalar $config->{real}{$server}{accounts}->@* == 0;

                $result->{$server} = {
                    host     => $config->{real}{$server}{server}{name},
                    port     => $config->{real}{$server}{server}{port},
                    login    => $config->{real}{$server}{manager}{login},
                    password => $config->{real}{$server}{manager}{password},
                    ranges   => $config->{real}{$server}{accounts},
                };
            }
        }
    } catch ($err) {
        $log->errorf('Failed to load or process YAML file: %s', $err);
        $result = undef;
    }

    if (defined $result and scalar keys %$result < 2) {
        $log->errorf('Need configuration for at least two servers to continue');
        $result = undef;
    }

    return $result;
}

=head2 _generate_password

Generates a password based on a seed string and the current time.

This subroutine generates a password by taking a seed string, appending the current time, applying SHA-384 hashing, and then truncating the result to 15 characters. 
It appends 'Hx_0' to the end of the truncated hash to form the final password.

=cut

sub _generate_password {
    my ($seed_str) = @_;
    my $pwd = substr(sha384_hex($seed_str, Time::Moment->now()), 0, 15);
    return $pwd . 'Hx_0';
}

=head2 _parse_server_key

Parses a server key to extract and transform server identifiers.

This subroutine takes a server key and determines whether it's in the old format (just a numeric ID) or the new format (prefixed with 'p01_ts'). 
It then provides both the old and new format of the server ID in a hash.

=cut

sub _parse_server_key {
    my ($server) = @_;

    my %result = (
        old => undef,
        new => undef
    );

    if ($server =~ /^\d+$/) {
        $result{old} = $server;
        $result{new} = "p01_ts${server}";
    } else {
        ($result{old}) = $server =~ /p\d+_ts(\d+)/;
        $result{new} = $server;
    }

    return %result;
}

=head2 _get_accounts_from_database

Retrieves MT5 account IDs associated with a given partner ID from the database.

=cut

sub _get_accounts_from_database {
    my ($partner_id) = @_;
    my $dbic         = BOM::Database::UserDB::rose_db()->dbic;
    my $accounts     = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(q{SELECT * FROM mt5.list_partner_accounts(?)}, {Slice => {}}, $partner_id);
        });

    my %mt5_accounts   = ();
    my @config_servers = keys %my_servers;

    for my $acc (@$accounts) {
        my $srv_key = ($config_servers[0] =~ /^\d+$/) ? $acc->{mt5_server_id} : $acc->{mt5_server_key};
        $mt5_accounts{$srv_key} = $acc->{mt5_account_id} if defined $acc->{mt5_account_id} and defined $srv_key;
    }

    return %mt5_accounts;
}

=head2 _add_to_notifications

Adds a notification entry for an MT5 account operation.

=cut

sub _add_to_notifications {
    my ($notifs, $status, $error, $account_type, $server, $mt5_id, $binary_user_id, $partner_id) = @_;
    $notifs->{$mt5_id} = {
        status       => $status,
        error        => $error // '',
        binary_id    => $binary_user_id,
        partner_id   => $partner_id,
        account_type => $account_type,
        server       => $server,
    };
}

=head2 _prepare_mt5_accounts_info

Prepares user information for MT5 account creation based on server and account defaults.

=cut

sub _prepare_mt5_accounts_info {
    my ($server, $user_information, $main_account_currency, $mt5_id_with_prefix) = @_;
    for my $def (keys %tech_defaults) {
        if ($def eq 'group') {
            my $group_string = ($server =~ /^p\d+_ts\d+$/) ? $tech_defaults{group} : undef;
            if ($group_string) {
                $user_information->{$def} = sprintf $group_string, $server, $main_account_currency;
            } else {
                $log->errorf("Unrecognize server[%s] for creating IB's target group", $server);
                delete $user_information->{$def};
            }
        } elsif ($def eq 'comment') {
            $user_information->{$def} = $mt5_id_with_prefix;
            $user_information->{$def} =~ s/\D//g;    # Remove non-digit characters from comment field
        } elsif ($def eq 'mainPassword' || $def eq 'investPassword') {
            $user_information->{$def} = _generate_password($mt5_id_with_prefix);
        } else {
            $user_information->{$def} = $tech_defaults{$def};
        }
    }
    return $user_information;
}

=head2 _send_email_to_marketing_team

Sends a marketing email with a report of MT5 account creation operations.

=cut

sub _send_email_to_marketing_team {
    my ($notifs) = @_;

    my %tables = (
        Success => [],
        Failed  => [],
    );

    for my $mt5_id (keys %$notifs) {
        my $notif        = $notifs->{$mt5_id};
        my $status_color = $notif->{status} eq 'Success' ? 'green' : 'red';
        my $entry        = sprintf(
            "<tr class='center-text'><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td style='color: %s;'>%s</td><td>%s</td></tr>",
            $notif->{account_type},
            $notif->{binary_id}, $notif->{partner_id}, $notif->{server}, $mt5_id, $status_color, $notif->{status}, $notif->{error} // ''
        );

        push @{$tables{$notif->{status} eq 'Success' ? 'Success' : 'Failed'}}, $entry;
    }

    my $build_table = sub {
        my ($title, $entries) = @_;
        return (
            $title,
            @{$entries}
            ? (
                "<table border='1' class='center-text'><tr style='background-color: #f2f2f2;'><th>Account Type</th><th>Binary User ID</th><th>Partner ID</th><th>Server</th><th>MT5 Account ID</th><th>Status</th><th>Error</th></tr>",
                @$entries, "</table>"
                )
            : ('No record.'));
    };

    my @message = (
        '<style>.center-text td { text-align: center; }</style>',
        '<h2>Successful Actions:</h2>',
        $build_table->('', $tables{Success}),
        '<br/><h2>Failures:</h2>', $build_table->('', $tables{Failed}),
    );

    send_email({
        from                  => 'no-reply@regentmarkets.com',
        to                    => 'x-marketingops@regentmarkets.com',
        subject               => sprintf('(%s) Partner Account Creation Report', Time::Moment->now->minus_days(1)->strftime('%F')),
        message               => \@message,
        email_content_is_html => 1,
    });
}

1;
