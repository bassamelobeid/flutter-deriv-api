package BOM::Event::Actions::CustomerStatement;

use strict;
use warnings;

no indirect;

use Syntax::Keyword::Try;

use Date::Utility;
use List::UtilsBy qw( rev_nsort_by );
use Log::Any      qw($log);
use Email::Stuffer;

use BOM::User::Client;
use BOM::Transaction;
use BOM::Platform::Context    qw (localize request);
use BOM::Transaction::History qw(get_transaction_history);
use BOM::Transaction::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

use Format::Util::Numbers qw(formatnumber);

use Finance::Contract::Longcode qw(shortcode_to_longcode shortcode_to_parameters);
use BOM::Event::Utility         qw(exception_logged);

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
    my $company = $client->landing_company;
    # result may not be available for clients with no currency
    my $result          = $account ? (values %$summary)[0] : {};
    my $estimated_value = ($result->{ending_balance} // 0) + ($transactions->{estimated_profit} // 0);

    my $data = {
        client => {
            %$result,
            open_trades     => $transactions->{open_trades},
            closed_trades   => $transactions->{closed_trades},
            payments        => $transactions->{payments},
            escrow          => $transactions->{escrow},
            is_mf_client    => ($company->short eq 'maltainvest') ? 1                                                                : 0,
            estimated_value => $account                           ? formatnumber('price', $account->currency_code, $estimated_value) : '',
            name            => $client->first_name . ' ' . $client->last_name,
            account_number  => $client->loginid,
            classification  => $client->status->professional ? 'Professional'          : 'Retail',
            currency        => $account                      ? $account->currency_code : 'No Currency Selected',
        },
        date      => Date::Utility->today->date_yyyymmdd(),
        statement => {
            start_date => $date_from->datetime_yyyymmdd_hhmmss(),
            end_date   => $date_to->datetime_yyyymmdd_hhmmss(),
        },
        offerings_available => defined($company->default_product_type),
    };
    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/quarterly_statement.html.tt', $data, \my $html);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return {status_code => 0};
    }

    my $system_generated_email = request()->brand->emails('system_generated');
    my $support_email          = request()->brand->emails('support');
    my $email_subject =
        $params->{email_subject} ? $params->{email_subject} : 'Statement from ' . $date_from->date_ddmmmyy() . ' to ' . $date_to->date_ddmmmyy();

    my $email_status = Email::Stuffer->from($support_email)->to($client->email)->subject($email_subject)->html_body($html)->send();
    unless ($email_status) {
        $log->warn('failed to send statement to ' . $client->email);
        return {status_code => 0};
    }

    if ($send_to_support) {
        $email_status = Email::Stuffer->from($system_generated_email)->to($support_email)->subject($email_subject)->html_body($html)->send();
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
    } catch ($e) {
        $log->warn("error in selling expired contracts\ncaught error: $e");
        exception_logged();
    }

    my $history = get_transaction_history({
        client => $client,
        args   => $params,
    });
    my $transactions = {estimated_profit => 0};

    # return empty if no account
    return $transactions unless $client->account;

    my $now      = Date::Utility->new();
    my $currency = $client->account->currency_code;

    for my $txn (@$history) {

        my $txn_time = Date::Utility->new($txn->{transaction_time});
        $txn->{transaction_date} = $txn_time->datetime_yyyymmdd_hhmmss;

        # categorize transactions
        if ($txn->{payment_id}) {
            push($transactions->{payments}->@*, $txn);
        } elsif ($txn->{referrer_type} eq 'p2p') {
            push($transactions->{escrow}->@*, $txn);
        } elsif ($txn->{financial_market_bet_id}) {
            # localize longcodes
            if ($txn->{short_code}) {
                try {
                    $txn->{long_code} = localize(shortcode_to_longcode($txn->{short_code}, $client->{currency}));
                } catch {
                    # we do not want to warn for known error like legacy underlying
                    if ($_ !~ /unknown underlying/) {
                        $log->warn("exception is thrown when executing shortcode_to_longcode, parameters: " . $txn->short_code . ' error: ' . $_);
                    }
                    $txn->{long_code} = localize('No information is available for this contract.');
                    exception_logged();
                }
            } else {
                $txn->{long_code} //= localize($txn->{payment_remark} // '');
            }

            if ($txn->{is_sold}) {
                push($transactions->{closed_trades}->@*, $txn);
            } else {
                # open contracts
                $txn->{expiry_time} = Date::Utility->new($txn->{expiry_time});
                $txn->{start_time}  = Date::Utility->new($txn->{start_time});

                # profit, calculate indicative price and estimated profit
                my $bet_parameters = shortcode_to_parameters($txn->{short_code}, $currency);
                if ($txn->{bet_class} eq 'multiplier') {
                    $bet_parameters->{limit_order} = BOM::Transaction::Utility::extract_limit_orders($txn);
                }
                my $contract = produce_contract($bet_parameters);
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

                push($transactions->{open_trades}->@*, $txn);
            }
        }
    }
    return $transactions;
}

1;
