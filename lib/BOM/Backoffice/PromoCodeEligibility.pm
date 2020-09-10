package BOM::Backoffice::PromoCodeEligibility;
use strict;
use warnings;

use Log::Any qw($log);
use JSON::MaybeXS;
use Syntax::Keyword::Try;
use List::Util qw(any first all sum min);

use BOM::Database::ClientDB;
use BOM::MyAffiliates;
use LandingCompany::Registry;
use BOM::User::Client;
use Email::Stuffer;
use Date::Utility;

my %currency_types;
my $report;

=head2 approve_all

Main entry point for cron script.
Intended to be run daily. It will have no bad effects if run more than once. 

=over 4

=item * For all active real non-crypto clients with affiliate codes, retrieve affiliate info from MyAffiliates

=item * Find promocodes assigned to these affiliates in MyAffiliates

=item * Add the promocodes to affiliated clients if they don't already have a promocode

=item * Check eligibility of all promocodes assigned to clients that are valid now

=item * Mark the eligble promocodes with status APPROVAL. This will make them appear in backoffice for the payout to be manually approved.

=back

=cut

sub approve_all {

    my $myaff_api = BOM::MyAffiliates->new();
    my $dbs       = connect_dbs();

    my $tokens = tokens_with_clients($dbs);
    my %affiliates;

    # Get affiliate ids for tokens
    if (my $decoded_tokens = $myaff_api->decode_token(keys %$tokens)) {
        # response is like this:
        # TOKEN => [
        #    {
        #       'PREFIX' => affilliate token,
        #       'USER_ID' => affiliate id,

        my @myaff_tokens = ref $decoded_tokens->{TOKEN} eq 'ARRAY' ? $decoded_tokens->{TOKEN}->@* : ($decoded_tokens->{TOKEN});

        $affiliates{$_->{USER_ID}}{buid} = $tokens->{$_->{PREFIX}} for @myaff_tokens;
    }

    # Get all promo codes assigned in myaffiliates. SQL wildcards are supported.
    if (
        my $aff_promos = $myaff_api->get_users(
            VARIABLE_NAME  => 'betonmarkets_promo_code',
            VARIABLE_VALUE => ';%;'
        ))
    {

        # response is like this:
        # 'USER => [
        #   'ID' => affiliate id,
        #   {
        #       'USER_VARIABLES' => {
        #           'VARIABLE' => [
        #               {
        #                    'NAME' => 'betonmarkets_promo_code',
        #                    'VALUE' => ';12542F20;BON2015;',
        my @myaff_users = ref $aff_promos->{USER} eq 'ARRAY' ? $aff_promos->{USER}->@* : ($aff_promos->{USER});

        USERS: for my $aff (@myaff_users) {
            next unless exists $affiliates{$aff->{ID}};

            foreach my $var ($aff->{USER_VARIABLES}->{VARIABLE}->@*) {
                if ($var->{NAME} eq 'betonmarkets_promo_code') {
                    my @codes = ($var->{VALUE} =~ /(?<=;)(\w+);/g);
                    $affiliates{$aff->{ID}}{codes} = [map { uc } @codes];
                    next USERS;
                }
            }
        }
    }

    my $all_codes = active_promocodes($dbs->{collector});

    add_codes_to_clients(\%affiliates, $all_codes);

    my $promo_clients = clients_with_promo($dbs);

    for my $buid (values %$promo_clients) {
        my $code_info = $all_codes->{$buid->{code}} or next;
        next if $buid->{code_used};    # don't approve any binary user who already has an approved/used promo code

        # serves as a sanity check for codes that were manually applied to the wrong account
        my ($client, $code) = code_for_account([$code_info], [values $buid->{clients}->%*]);
        next unless $client && $code;

        my $is_approved;

        if ($code->{promo_code_type} eq 'FREE_BET') {
            # At this point, welcome bonuses can be approved
            $is_approved = 1;
        } elsif ($code->{promo_code_type} eq 'GET_X_WHEN_DEPOSIT_Y') {
            # Get all deposits with amount >= promocode deposit requirement
            my @deposits = grep { $_ >= $code->{min_deposit} } get_deposits($dbs->{$client->{broker}}, $client->{account_id}, $code->{code}, $code);
            # Approve is there is at least one and client has sufficient turnover
            $is_approved = 1
                if @deposits > 0 and turnover_requirement_met($dbs->{$client->{broker}}, $client, $code, $code->{amount}, sum(@deposits));
        } elsif ($code->{promo_code_type} eq 'GET_X_OF_DEPOSITS') {
            # Get payout amount
            my ($bonus, $deposit_total) = get_dynamic_bonus(
                db           => $dbs->{$client->{broker}},
                account_id   => $client->{account_id},
                code         => $code->{code},
                promo_config => $code,
            );
            # Approve if there is a bonus and client has sufficient turnover
            $is_approved = 1 if $bonus > 0 and turnover_requirement_met($dbs->{$client->{broker}}, $client, $code, $bonus, $deposit_total);
        }

        if ($is_approved) {
            $dbs->{$client->{broker}}->run(
                fixup => sub {
                    $_->do(
                        "UPDATE betonmarkets.client_promo_code SET status = 'APPROVAL' 
                        WHERE client_loginid = ? AND promotion_code = ? AND status NOT IN ('CLAIM','REJECT','CANCEL')",
                        undef, $client->{loginid}, $code->{code});
                });
            push $report->{promos_approved}->@*,
                {
                loginid => $client->{loginid},
                code    => $code->{code},
                type    => $code->{promo_code_type}};
        }
    }

    my $body = "<h3>Affiliate promo codes added to affiliated clients</h3>\n";
    if ($report->{affiliate_promos_added}) {
        $body .= "<table border=1 style=\"border-collapse:collapse;\"><tr><th>Client</th><th>Affiliate ID</th><th>Promo code</th></tr>\n";
        for my $item ($report->{affiliate_promos_added}->@*) {
            $body .= "<tr><td>" . $item->{loginid} . "</td><td>" . $item->{affiliate} . "</td><td>" . $item->{code} . "</td></tr>\n";
        }
        $body .= "</table>";
    } else {
        $body .= "<p>None</p>\n";
    }

    $body .= "<h3>Client promo codes moved to approval</h3>\n";
    if ($report->{promos_approved}) {
        $body .= "<table border=1 style=\"border-collapse:collapse;\"><tr><th>Client</th><th>Promo code</th><th>Promo type</th></tr>\n";
        for my $item ($report->{promos_approved}->@*) {
            $body .= "<tr><td>" . $item->{loginid} . "</td><td>" . $item->{code} . "</td><td>" . $item->{type} . "</td></tr>\n";
        }
        $body .= "</table>";
    } else {
        $body .= "<p>None</p>\n";
    }

    if ($report->{duplicate_tokens}) {
        $body .= "<h3>Clients with multiple affiliate tokens</h3>\n";
        $body .= "<table border=1 style=\"border-collapse:collapse;\"><tr><th>Clients</th><th>Affiliate tokens</th></tr>\n";
        for my $item ($report->{duplicate_tokens}->@*) {
            $body .= "<tr><td>";
            $body .= join ', ', keys $item->{loginids}->%*;
            $body .= "</td><td>";
            $body .= join ', ', keys $item->{tokens}->%*;
            $body .= "</td></tr>\n";
        }
        $body .= "</table>";
    }

    if ($report->{duplicate_promo}) {
        $body .= "<h3>Clients with multiple promo codes</h3>\n";
        $body .= "<table border=1 style=\"border-collapse:collapse;\"><tr><th>Clients</th><th>Promo codes</th></tr>\n";
        for my $item ($report->{duplicate_promo}->@*) {
            $body .= "<tr><td>";
            $body .= join ', ', keys $item->{loginids}->%*;
            $body .= "</td><td>";
            $body .= join ', ', keys $item->{codes}->%*;
            $body .= "</td></tr>\n";
        }
        $body .= "</table>";
    }

    my $from    = 'Nightly promo code processing script <x-backend@binary.com>';
    my $to      = 'Affiliates team <x-affiliates@binary.com>';
    my $subject = 'Promo code processing report for ' . Date::Utility->new->date;

    Email::Stuffer->from($from)->to($to)->subject($subject)->html_body($body)->send
        || warn "Sending email from $from to $to subject $subject failed";

    return 0;
}

=head2 connect_dbs

Create db connections for all needed dbs.

=cut

sub connect_dbs {
    my %dbs;

    $dbs{collector} = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        })->db->dbic;

    my $brokers = $dbs{collector}->run(
        fixup => sub {
            return $_->selectcol_arrayref('SELECT * FROM betonmarkets.production_servers()');
        });

    for my $broker (@$brokers) {
        $dbs{$broker} = BOM::Database::ClientDB->new({broker_code => uc $broker})->db->dbic;
    }

    return \%dbs;
}

=head2 tokens_with_clients

Gets all clients who are active, non-crypto and have an affiliate token.

=cut

sub tokens_with_clients {
    my $dbs = shift;

    my %tokens;
    my %duplicates;

    for my $broker (keys %$dbs) {
        next if $broker eq 'collector';

        my $clients = $dbs->{$broker}->run(
            fixup => sub {
                return $_->selectall_arrayref(
                    "SELECT c.loginid, c.myaffiliates_token token, c.binary_user_id buid, a.currency_code currency, c.residence, EXTRACT(epoch FROM c.date_joined) date_joined
                        FROM betonmarkets.client c
                        JOIN transaction.account a ON a.client_loginid = c.loginid
                        LEFT JOIN betonmarkets.client_status s ON s.client_loginid = c.loginid AND s.status_code in('unwelcome','disabled')
                        WHERE c.myaffiliates_token != '' AND s.id IS NULL",
                    {Slice => {}});
            });

        my %buid_check;    # to check ambiguous affiliate tokens
        for my $client (grep { ($currency_types{$_->{currency}} //= LandingCompany::Registry::get_currency_type($_->{currency}) eq 'fiat') }
            @$clients)
        {
            $duplicates{$client->{buid}}{tokens}{$client->{token}}     = 1;
            $duplicates{$client->{buid}}{loginids}{$client->{loginid}} = 1;

            if (exists $buid_check{$client->{buid}} && $buid_check{$client->{buid}} ne $client->{token}) {
                next;
            }
            $tokens{$client->{token}}{$client->{buid}}{$client->{loginid}} = $client;
            $buid_check{$client->{buid}} = $client->{token};
        }
    }

    for my $dup (grep { keys $duplicates{$_}{tokens}->%* > 1 } keys %duplicates) {
        push $report->{duplicate_tokens}->@*, $duplicates{$dup};
    }

    return \%tokens;
}

=head2 active_promocodes

Gets all promocodes that are active at the current time.

=cut

sub active_promocodes {
    my $db = shift;

    my $ts   = time;
    my $json = JSON::MaybeXS->new;
    my %result;

    my $db_codes = $db->run(
        fixup => sub {
            return $_->selectall_arrayref(
                "SELECT EXTRACT (day FROM (expiry_date - to_timestamp($ts))) days_left, 
                        EXTRACT (epoch from start_date) start_date,
                        EXTRACT (epoch from expiry_date) expiry_date,
                        UPPER(code) code, promo_code_type, promo_code_config 
                FROM betonmarkets.promo_code 
                    WHERE status 
                        AND ( start_date IS NULL OR extract(epoch from start_date) <= $ts )
                        AND ( expiry_date IS NULL OR extract (epoch from expiry_date) >= $ts )",
                {Slice => {}});
        });

    for my $code (@$db_codes) {
        my $config;
        try {
            $config = $json->decode($code->{promo_code_config});
            $config->{country} = [split ',', $config->{country}];
        } catch {
            warn 'Invalid config for promocode ' . $code->{code} . ': ' . $@;
            next;
        }
        $result{$code->{code}} = $code;
        $result{$code->{code}}{$_} = $config->{$_} for keys $config->%*;
    }

    return \%result;
}

=head2 code_for_account

Takes a list of promocodes and a list of accounts, and chooses the best match if any.

=cut

sub code_for_account {
    my ($codes, $accounts) = @_;

    my (@filtered_accounts, @filtered_codes);

    # Filter out accounts which have no valid code
    for my $account (@$accounts) {
        next unless any { uc $_->{currency} eq 'ALL' || uc $_->{currency} eq uc $account->{currency} } @$codes;
        next unless any {
            any { uc $_ eq 'ALL' || uc $_ eq uc $account->{residence} } $_->{country}->@*
        }
        @$codes;
        next unless any {
            (!$_->{start_date} || $account->{date_joined} >= $_->{start_date})
                && (!$_->{expiry_date} || $account->{date_joined} <= $_->{expiry_date})
        }
        @$codes;
        push @filtered_accounts, $account;
    }

    # If more than one, prefer MF
    if (@filtered_accounts > 1) {
        @filtered_accounts = sort { $b->{loginid} =~ /^MF/ } @filtered_accounts;
    }

    # Filter out promocodes which can't be applied to any account
    for my $code (@$codes) {
        next unless any { uc $code->{currency} eq 'ALL' || uc $code->{currency} eq uc $_->{currency} } @filtered_accounts;
        next unless any {
            my $res = $_->{residence};
            any { uc $_ eq 'ALL' || uc $_ eq uc $res } $code->{country}->@*
        }
        @filtered_accounts;
        next unless any {
            (!$code->{start_date} || $_->{date_joined} >= $code->{start_date})
                && (!$code->{expiry_date} || $_->{date_joined} <= $code->{expiry_date})
        }
        @filtered_accounts;
        push @filtered_codes, $code;
    }

    # If more than one, prefer the longest expiry
    if (@filtered_codes > 1) {
        @filtered_codes = sort { ($b->{days_left} // 9999) <=> ($a->{days_left} // 9999) } @filtered_codes;
    }

    return unless @filtered_accounts && @filtered_codes;
    return ($filtered_accounts[0], $filtered_codes[0]);
}

=head2 add_codes_to_clients

For a list of affiliates, adds promocodes to client accounts if they don't have one already.

=cut

sub add_codes_to_clients {
    my ($affiliates, $all_codes) = @_;

    for my $aff_id (keys %$affiliates) {
        my $aff = $affiliates->{$aff_id};
        my @codes_to_check;
        my @codes_exist = grep { exists $all_codes->{$_} } ($aff->{codes} // [])->@*;
        next unless @codes_exist;
        @codes_to_check = $all_codes->@{@codes_exist};

        for my $buid (values $aff->{buid}->%*) {
            my ($client, $code) = code_for_account(\@codes_to_check, [values %$buid]);
            next unless $client && $code;

            try {
                my $client = BOM::User::Client->new({loginid => $client->{loginid}});
                unless ($client->client_promo_code) {
                    $client->promo_code($code->{code});
                    $client->save;
                    push $report->{affiliate_promos_added}->@*,
                        {
                        affiliate => $aff_id,
                        loginid   => $client->loginid,
                        code      => $code->{code}};
                }
            } catch {
                warn $@;
            }
        }
    }
}

=head2 clients_with_promo

Gets all clients who are active, non-crypto and have an active promo code.

=cut

sub clients_with_promo {
    my $dbs = shift;

    my %clients;
    my %duplicates;

    for my $broker (keys %$dbs) {
        next if $broker eq 'collector';

        my $clients = $dbs->{$broker}->run(
            fixup => sub {
                return $_->selectall_arrayref(
                    "SELECT c.loginid, p.promotion_code code, p.status, c.binary_user_id buid, a.currency_code currency, a.id account_id, c.residence, EXTRACT(epoch FROM c.date_joined) date_joined
                       FROM betonmarkets.client c
                       JOIN transaction.account a ON a.client_loginid = c.loginid
                       JOIN betonmarkets.client_promo_code p ON p.client_loginid = c.loginid
                       LEFT JOIN betonmarkets.client_status s ON s.client_loginid = c.loginid AND s.status_code in('unwelcome','disabled')
                       WHERE s.id IS NULL",
                    {Slice => {}});
            });

        for my $client (grep { ($currency_types{$_->{currency}} //= LandingCompany::Registry::get_currency_type($_->{currency}) eq 'fiat') }
            @$clients)
        {
            $duplicates{$client->{buid}}{codes}{$client->{code}}       = 1;
            $duplicates{$client->{buid}}{loginids}{$client->{loginid}} = 1;
            if (exists $clients{$client->{buid}}{code} && $clients{$client->{buid}}{code} ne $client->{code}) {
                next;
            }
            $clients{$client->{buid}}{code}                        = $client->{code};
            $clients{$client->{buid}}{code_used}                   = 1 if $client->{status} =~ /^(APPROVAL|CLAIM|REJECT|CANCEL)$/;
            $client->{broker}                                      = $broker;
            $clients{$client->{buid}}{clients}{$client->{loginid}} = $client;
        }
    }
    for my $dup (grep { keys $duplicates{$_}{codes}->%* > 1 } keys %duplicates) {
        push $report->{duplicate_promo}->@*, $duplicates{$dup};
    }

    return \%clients;
}

=head2 get_deposits

Get amounts of eligible deposits

=cut

sub get_deposits {
    my ($db, $account_id, $code, $promo_config) = @_;
    my $pp = $promo_config->{payment_processor} // 'ALL';

    return $db->run(
        fixup => sub {
            my $sth = $_->prepare_cached(
                "SELECT p.amount FROM transaction.transaction t 
                JOIN payment.payment p ON p.id = t.payment_id AND p.payment_gateway_code IN ('payment_agent_transfer', 'doughflow', 'bank_wire', 'p2p')
                JOIN betonmarkets.promo_code pc ON pc.code = ?
                WHERE t.action_type = 'deposit'
                AND (pc.start_date IS NULL OR p.payment_time >= pc.start_date)
                AND (pc.expiry_date IS NULL OR p.payment_time <= pc.expiry_date)
                AND t.account_id = ?
                AND (? = 'ALL' or ( ? = REGEXP_REPLACE(p.remark,'(.+payment_processor=)(\\w+)(.*)', '\\2') AND p.payment_gateway_code = 'doughflow' ) )"
            );
            $sth->execute($code, $account_id, $pp, $pp);
            my $res = $sth->fetchall_arrayref;
            $sth->finish;
            return map { $_->[0] } @$res;
        });

}

=head2 turnover_requirement_met

Check if a client has sufficient turnover.
Turnover must be at least turnover_type x min_turnover.
turnover_type is 'bonus' if undefined.
min_turnover is 5 if undefined.

=cut

sub turnover_requirement_met {
    my ($db, $client, $code, $payout, $deposit) = @_;

    my $tover = $db->run(
        fixup => sub {
            my $sth = $_->prepare_cached(
                "SELECT COALESCE(SUM(ABS(amount)),0) FROM transaction.transaction t
                JOIN bet.financial_market_bet b ON b.id = t.financial_market_bet_id
                JOIN betonmarkets.promo_code pc ON pc.code = ?
                WHERE t.action_type = 'buy'
                AND (pc.start_date IS NULL OR b.purchase_time >= pc.start_date)
                AND (pc.expiry_date IS NULL OR b.purchase_time <= pc.expiry_date)                            
                AND t.account_id = ?"
            );
            $sth->execute($code->{code}, $client->{account_id});
            my $res = $sth->fetchrow_array;
            $sth->finish;
            return $res;
        });

    my $type   = $code->{turnover_type} // 'bonus';
    my $factor = $code->{min_turnover}  // 5;
    if ($type eq 'deposit') {
        return $tover >= ($deposit * $factor);
    } elsif ($type eq 'bonus') {
        return $tover >= ($payout * $factor);
    }
}

=head2 get_dynamic_bonus

Calculate bonus amount for GET_X_OF_DEPOSITS promos.
Used in this file as well as pages in BO where promocodes are manually approved.

=cut

sub get_dynamic_bonus {
    my %args = @_;

    my @deposits = get_deposits($args{db}, $args{account_id}, $args{code}, $args{promo_config});
    my $total    = sum(@deposits) // 0;
    my $bonus    = $total * ($args{promo_config}{amount} / 100);
    $bonus = min($bonus, $args{promo_config}{max_amount}) if $args{promo_config}{max_amount};
    $bonus = 0                                            if $args{promo_config}{min_amount} and $args{promo_config}{min_amount} > $bonus;
    return ($bonus, $total);
}

1;
