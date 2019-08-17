package BOM::Event::Actions::CustomerStatement;

use strict;
use warnings;

no indirect;

use Try::Tiny;
use Email::Stuffer;
use Date::Utility;
use List::UtilsBy qw( rev_nsort_by );
use Log::Any qw($log);

use BOM::User::Client;
use BOM::Transaction;
use BOM::Platform::Context qw (localize request);
use BOM::Transaction::History qw(get_transaction_history);
use BOM::Product::ContractFactory qw(produce_contract);
use Format::Util::Numbers qw(formatnumber);

use Finance::Contract::Longcode qw(shortcode_to_longcode);

use constant EPOCH_IN_MINUTE => 60;
use constant EPOCH_IN_HOUR   => EPOCH_IN_MINUTE * EPOCH_IN_MINUTE;
use constant EPOCH_IN_DAY    => EPOCH_IN_HOUR * 24;

=head2 email_statement

Send client an email statement

=over 4

=item * C<loginid> - login id of client to send the statement to

=item * C<source> - source to sell expired contracts

=item * C<date_from> - date from for statement in form of epoch

=item * C<date_to> - date to for statement in form of epoch

=item * C<email_subject> - Subject of the email (optional)

=item * C<cover_period> - Statement Cover Period (optional)

=back

Returns an integer whereby 1 represent email has been sent, and 0 means otherwise.

=cut

sub email_statement {
    my $data = shift;

    my $loginid = $data->{loginid};

    my $client = BOM::User::Client->new({loginid => $loginid});
    unless ($client) {
        $log->warn("client cannot be created");
        return 0;
    }

    $data->{client} = $client;

    my $res = _send_email_statement($data);
    return $res->{status_code};
}

sub _send_email_statement {
    my $params          = shift;
    my $client          = $params->{client};
    my $send_to_support = $params->{send_to_support_team} // 0;

    my $transactions = _retrieve_transaction_history($params, $client);

    my $date_from = Date::Utility->new($params->{date_from});
    my $date_to   = Date::Utility->new($params->{date_to});

    my $summary = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_hashref(
                'select * from quarterly_statement_summary(?, ?, ?)',
                'account_id', {},
                $date_from->datetime_yyyymmdd_hhmmss,
                $date_to->datetime_yyyymmdd_hhmmss,
                $client->loginid,
            );
        });

    # gather template data
    my $account = $client->account;
    # result may not be available for clients with no currency
    my $result = $account ? (values %$summary)[0] : {};
    my $estimated_value = ($result->{ending_balance} // 0) + ($transactions->{estimated_profit} // 0);

    my $data = {
        client => {
            %$result,
            open_trades     => $transactions->{open_trade},
            closed_trades   => $transactions->{close_trade},
            payments        => $transactions->{payment},
            is_mf_client    => ($client->landing_company->short eq 'maltainvest') ? 1 : 0,
            estimated_value => $account ? formatnumber('price', $account->currency_code, $estimated_value) : '',
            name            => $client->first_name . ' ' . $client->last_name,
            account_number  => $client->loginid,
            classification => $client->status->professional ? 'Professional' : 'Retail',
            currency => $account ? $account->currency_code : 'No Currency Selected',
        },
        date      => Date::Utility->today->date_yyyymmdd(),
        statement => {
            start_date => $date_from->datetime_yyyymmdd_hhmmss(),
            end_date   => $date_to->datetime_yyyymmdd_hhmmss(),
        }};

    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/quarterly_statement.html.tt', $data, \my $html);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return {status_code => 0};
    }

    my $support_email = request()->brand->emails('support');
    my $email_subject =
        $params->{email_subject} ? $params->{email_subject} : 'Statement from ' . $date_from->date_ddmmmyy() . ' to ' . $date_to->date_ddmmmyy();

    my $email_status = Email::Stuffer->from($support_email)->to($client->email)->subject($email_subject)->html_body($html)->send();
    unless ($email_status) {
        $log->warn('failed to send statement to ' . $client->email);
        return {status_code => 0};
    }

    if ($send_to_support) {
        $email_status = Email::Stuffer->from($support_email)->to($support_email)->subject($email_subject)->html_body($html)->send();
        $log->warn('failed to send statement to support team') unless $email_status;
    }

    return {
        status_code => 1,
    };
}

sub _retrieve_transaction_history {

    my ($params, $client) = @_;

    try {
        BOM::Transaction::sell_expired_contracts({
            client => $client,
            source => $params->{source},
        });
    }
    catch {
        $log->warn("error in selling expired contracts\ncaught error: $_");
    };

    my $transactions = get_transaction_history({
        client => $client,
        args   => $params,
    });

    # sort the email by transaction time
    my $sort_by_transaction = sub {
        return rev_nsort_by { $_->{transaction_time} } @{$transactions->{+shift}};
    };

    $transactions->{payment}     = [$sort_by_transaction->('payment')];
    $transactions->{close_trade} = [$sort_by_transaction->('close_trade')];
    $transactions->{open_trade}  = [$sort_by_transaction->('open_trade')];

    # return empty if account does not have any transactions
    return $transactions unless $client->account;

    my $now      = Date::Utility->new();
    my $currency = $client->account->currency_code;

    $transactions->{estimated_profit} = 0;
    for my $txn (@{$transactions->{open_trade}}, @{$transactions->{close_trade}}, @{$transactions->{payment}}) {

        my $txn_time = Date::Utility->new($txn->{transaction_time});
        $txn->{transaction_date} = $txn_time->datetime_yyyymmdd_hhmmss;

        # localize longcodes
        if ($txn->{short_code}) {
            try {
                $txn->{long_code} = localize(shortcode_to_longcode($txn->{short_code}, $client->{currency}));
            }
            catch {
                # we do not want to warn for known error like legacy underlying
                if ($_ !~ /unknown underlying/) {
                    $log->warn("exception is thrown when executing shortcode_to_longcode, parameters: " . $txn->short_code . ' error: ' . $_);
                }
                $txn->{long_code} = localize('No information is available for this contract.');
            }
        } else {
            $txn->{long_code} //= localize($txn->{payment_remark} // '');
        }

        # open contracts
        if (!$txn->{is_sold} && !$txn->{payment_id}) {

            $txn->{expiry_time} = Date::Utility->new($txn->{expiry_time});
            $txn->{start_time}  = Date::Utility->new($txn->{start_time});

            # profit, calculate indicative price and estimated profit
            my $contract = produce_contract($txn->{short_code}, $currency);
            if (defined $txn->{buy_price} and (defined $contract->bid_price or defined $contract->{sell_price})) {
                $txn->{profit} =
                    $contract->{sell_price}
                    ? formatnumber('price', $currency, $contract->{sell_price} - $txn->{buy_price})
                    : formatnumber('price', $currency, $contract->{bid_price} - $txn->{buy_price});

                $txn->{indicative_price} = formatnumber('price', $currency, $txn->{buy_price} + $txn->{profit});
                $transactions->{estimated_profit} += $txn->{profit};
            }

            # get remaining days left for open contracts
            my $remaining_time = Date::Utility->new($txn->{expiry_time})->epoch - $now->epoch;
            if ($remaining_time > EPOCH_IN_DAY) {
                $remaining_time = POSIX::floor($remaining_time / EPOCH_IN_DAY) . ' Days';
            } elsif ($remaining_time > EPOCH_IN_HOUR) {
                $remaining_time = POSIX::floor($remaining_time / EPOCH_IN_HOUR) . ' Hours';
            } elsif ($remaining_time > EPOCH_IN_MINUTE) {
                $remaining_time = POSIX::floor($remaining_time / EPOCH_IN_MINUTE) . ' Minutes';
            } else {
                $remaining_time = $remaining_time . ' Seconds';
            }

            $txn->{remaining_time} = $remaining_time;
        }
    }
    return $transactions;
}

1;
