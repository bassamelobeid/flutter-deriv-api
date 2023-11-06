package BOM::Backoffice::CommissionTool;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Data::Dumper;
use Format::Util::Numbers qw(financialrounding);
use Syntax::Keyword::Try;
use BOM::Database::CommissionDB;
use BOM::User::Client;
use Scalar::Util qw(looks_like_number);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::Config::Redis;
use JSON::MaybeXS qw(decode_json);

=head2 get_commission_by_provider

Fetch commission rate details by CFD provider. (E.g. dxtrade)

Returns a hash reference of commission rate by market

=cut

sub get_commission_by_provider {
    my $provider = shift;

    my $db = BOM::Database::CommissionDB::rose_db();

    my $commissions = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(q{SELECT * FROM affiliate.get_commission_by_provider(?)}, undef, $provider);
        });

    die 'currently only supports dxtrade' if $provider ne 'dxtrade';

    my $config      = BOM::Config::Redis::redis_cfds()->hgetall('DERIVX_CONFIG::INSTRUMENT_LIST');
    my %symbols_map = $config->@*;
    my $by_market;
    foreach my $data (sort { $a->[2] cmp $b->[2] } $commissions->@*) {
        my ($account_type, $type, $symbol, $rate, $contract_size) = $data->@*;
        my $symbol_config = decode_json($symbols_map{$symbol} // '{}');
        if (not %$symbol_config) {
            warn "missing symbol configuration for $symbol, from provider $provider";
            next;
        }
        push @{$by_market->{$symbol_config->{type}}},
            {
            symbol        => $symbol,
            account_type  => $account_type,
            type          => $type,
            rate          => $rate,
            contract_size => $contract_size,
            };
    }

    return $by_market;
}

=head2 save_commission

Saves commission rate into commission DB

=over 4

=item + C<$args{symbol}> - underlying symbol (E.g. frxUSDJPY)
=item + C<$args{provider}> - Affiliate provider (E.g. myaffiliate)
=item + C<$args{account_type}> - account grouping (E.g. standard or stp)
=item + C<$args{commission_type}> - type of commission scheme (E.g. volume or spread)
=item + C<$args{commission_rate}> - commission to be charged
=item + C<$args{contract_size}> - contract size


=back

=cut

sub save_commission {
    my $args = shift;

    return {error => 'symbol is required'}              unless $args->{symbol};
    return {error => 'provider is required'}            unless $args->{provider};
    return {error => 'account_type is required'}        unless $args->{account_type};
    return {error => 'commission_type is required'}     unless $args->{commission_type};
    return {error => 'contract_size must be numeric'}   unless defined $args->{contract_size}   and looks_like_number($args->{contract_size});
    return {error => 'commission_rate must be numeric'} unless defined $args->{commission_rate} and looks_like_number($args->{commission_rate});
    return {error => 'commission_rate must be less than 1'} if $args->{commission_rate} >= 1;

    # remove whitetespace at the beginning or end of symbol
    $args->{symbol} =~ s/^\s+//g;
    $args->{symbol} =~ s/\s+$//g;
    my @symbols = split ',', $args->{symbol};

    my $output = {success => 1};
    my $db     = BOM::Database::CommissionDB::rose_db();
    my @success;
    my @fail;

    foreach my $symbol (@symbols) {
        try {
            $db->dbic->run(
                ping => sub {
                    $_->do(
                        q{SELECT * FROM affiliate.add_new_commission_rate(?,?,?,?,?,?)},
                        undef, $args->{provider}, $args->{account_type}, $args->{commission_type},
                        $symbol,
                        $args->{commission_rate},
                        $args->{contract_size});
                });
            push @success, $symbol;
        } catch ($e) {
            push @fail, $symbol;
        }
    }

    if (@fail) {
        $output = {error => sprintf("Failed to save [%s]", (join ', ', @fail))};
    }

    return $output;
}

=head2 delete_commission

Delete commission rate in commission DB

=over 4

=item + C<$args{symbol}> - underlying symbol (E.g. frxUSDJPY)
=item + C<$args{provider}> - Affiliate provider (E.g. myaffiliate)
=item + C<$args{account_type}> - account grouping (E.g. standard or stp)
=item + C<$args{commission_type}> - type of commission scheme (E.g. volume or spread)


=back

=cut

sub delete_commission {
    my $args = shift;

    return {error => 'symbol is required'}          unless $args->{symbol};
    return {error => 'provider is required'}        unless $args->{provider};
    return {error => 'account_type is required'}    unless $args->{account_type};
    return {error => 'commission_type is required'} unless $args->{commission_type};

    # remove whitetespace at the beginning or end of symbol
    $args->{symbol} =~ s/^\s+//g;
    $args->{symbol} =~ s/\s+$//g;
    my @symbols = split ',', $args->{symbol};

    my $output = {success => 1};
    my $db     = BOM::Database::CommissionDB::rose_db();
    my @success;
    my @fail;
    foreach my $symbol (@symbols) {
        try {
            $db->dbic->run(
                ping => sub {
                    $_->do(
                        q{
                SELECT *
                FROM affiliate.delete_commission_rate(?,?,?,?)
            },
                        undef,
                        $args->{provider},
                        $args->{account_type},
                        $args->{commission_type},
                        $symbol
                    );
                });
            push @success, $symbol;
        } catch ($e) {
            push @fail, $symbol;
        }
    }
    if (@fail) {
        $output = {error => sprintf("Failed to delete [%s]", (join ', ', @fail))};
    }

    return $output;
}

=head2 save_affiliate_payment_details

Save affiliate payment loginid and currency into commission DB

=over 4

=item + C<$args{provider}> - Affiliate provider (E.g. myaffiliate)
=item + C<$args{payment_loginid}> - Deriv's client loginid
=item + C<$args{affiliate_id}> - External affiliate id (E.g. MyAffiliates ID)

=back

=cut

sub save_affiliate_payment_details {
    my $args = shift;

    return {error => 'provider is required'}        unless $args->{provider};
    return {error => 'payment_loginid is required'} unless $args->{payment_loginid};
    return {error => 'affiliate_id is required'}    unless $args->{affiliate_id};

    $args->{affiliate_id}    =~ s/\s+//g;
    $args->{payment_loginid} =~ s/\s+//g;

    my @affiliate_ids    = split ',', $args->{affiliate_id};
    my @payment_loginids = split ',', $args->{payment_loginid};

    if (@affiliate_ids != @payment_loginids) {
        return {error => 'mismatch affiliate_id and payment_loginid'};
    }

    my $output = {success => 1};
    my $db     = BOM::Database::CommissionDB::rose_db();
    my (@success, @fail);
    for my $index (0 .. $#affiliate_ids) {
        my $aff_id     = $affiliate_ids[$index];
        my $payment_id = $payment_loginids[$index];
        my $msg        = "$aff_id-$payment_id";

        my $user;
        try {
            $user = BOM::User::Client->new({loginid => uc $payment_id});
        } catch {
            $msg .= ' invalid payment ID';
        };

        if (!$user || $user->is_virtual) {
            # payment_id does not exist or it is a virtual account
            push @fail, $msg;
            next;
        }

        try {
            $db->dbic->run(
                ping => sub {
                    $_->do(q{select * from affiliate.add_new_affiliate(?,?,?,?,?)},
                        undef, $user->binary_user_id, $aff_id, $payment_id, $user->currency, $args->{provider});
                });
            push @success, $msg;
        } catch ($e) {
            push @fail, $msg;
        }
    }

    if (@fail) {
        $output = {error => sprintf("Failed to update [%s]", (join ', ', @fail))};
    }

    return $output;
}

=head2 get_enum_type

Get enum type from commission DB

=cut

sub get_enum_type {
    my $type = shift;

    my $db     = BOM::Database::CommissionDB::rose_db();
    my $output = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(sprintf(q{select unnest(enum_range(NULL::%s))}, $type));
        });

    return [map { $output->[$_][0] } (0 .. $#$output)];
}

=head2 get_affiliate_info

Get affiliate payment details from commission DB

=over 4

=item + C<$args{provider}> - Affiliate  provider (E.g. myaffiliate)
=item + C<$args{affiliate_id}> - External affiliate id OR 
=item + C<$args{binary_user_id}> - binary user id for Deriv's user

=back

=cut

sub get_affiliate_info {
    my $args = shift;

    return {error => 'provider is required'}                       unless $args->{provider};
    return {error => 'affiliate_id or binary_user_id is required'} unless $args->{affiliate_id} or $args->{binary_user_id};

    my $db = BOM::Database::CommissionDB::rose_db();
    if (my $aff_id = $args->{affiliate_id}) {
        $aff_id =~ s/\s+//g;
        $aff_id = '{' . $aff_id . '}';
        my $out = $db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    q{select binary_user_id, external_affiliate_id, payment_loginid, payment_currency from affiliate.affiliate where external_affiliate_id= any(?::TEXT[])},
                    undef, $aff_id
                );
            });
        return $out;
    }

    if (my $binary_user_id = $args->{binary_user_id}) {
        $binary_user_id =~ s/\s+//g;
        $binary_user_id = '{' . $binary_user_id . '}';
        my $out = $db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    q{select binary_user_id, external_affiliate_id, payment_loginid, payment_currency from affiliate.affiliate where binary_user_id= any(?::BIGINT[])},
                    undef, $binary_user_id
                );
            });
        return $out;
    }

    return [];
}

=head2 get_transaction_info

Get calculated commission information from the commission DB

=over 4

=item + C<$args{provider}> - Affiliate provider (E.g. myaffiliate)
=item + C<$args{date}> - request date string (E.g. 2021-05-01 10:23:00)
=item + C<$args{cfd_provider}> - CFD provider (E,g. dxtrade)
=item + C<$args{affiliate_id}> - affiliate id (optional)

=back

=cut

sub get_transaction_info {
    my $args = shift;

    return {error => 'provider is required'}     unless $args->{provider};
    return {error => 'cfd_provider is required'} unless $args->{cfd_provider};

    my $pay           = delete $args->{make_payment};
    my $previewed_hex = delete $args->{hex};
    # check sum
    my $string = join '', map { $_ . '' . ($args->{$_} // '') } sort { $a cmp $b } keys %$args;
    my $hex    = md5_hex($string);

    if ($pay and not $previewed_hex) {
        return {error => 'payment data is unverifed'};
    }

    if ($pay and $previewed_hex ne $hex) {
        return {error => 'payment request is different than the data previewed. Aborting payment'};
    }

    if ($args->{date}) {
        my $error = 0;
        try { Date::Utility->new($args->{date}) }
        catch { $error = 1 };
        return {error => 'invalid date format'} if $error;
    }

    my $db         = BOM::Database::CommissionDB::rose_db();
    my @query_args = ($args->{cfd_provider}, $args->{provider}, $args->{list_unpaid}, ($args->{date} || undef));
    if (my $aff_id = $args->{affiliate_id}) {
        $aff_id =~ s/\s+//g;
        $aff_id = '{' . $aff_id . '}';
        push @query_args, $aff_id;
    } else {
        push @query_args, undef;
    }

    my $sql = q{select * from transaction.get_commission_by_affiliate(?,?,?,?,?)};
    my $out = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql, undef, @query_args);
        });

    return _pay($out) if ($pay);

    return {
        headers => [
            'Deal ID',                  # 0
            'Login ID',                 # 1
            'Symbol',                   # 2
            'Volume',                   # 3
            'Spread',                   # 4
            'Price',                    # 5
            'Base Commission',          # 6
            'Base Currency',            # 7
            'Deal Transaction Time',    # 8
            'Commission',               # 9
            'Target Currency',          # 10
            'Calculated Time',          # 11
            'Payment Loginid',          # 12
            'Payment ID',               # 13
            'Exchange Rate'             # 14
        ],
        hex     => $hex,
        records => $out,
    };
}

=head2 _pay

Make payment to the records

=cut

sub _pay {
    my $out = shift;

    # group by payment_loginid
    my %group;
    foreach my $record (@$out) {
        my $deal_id         = $record->[0];
        my $commission      = $record->[9];
        my $currency        = $record->[10];
        my $payment_loginid = $record->[12];
        my $payment_id      = $record->[13];
        # we do not double pay
        next if $payment_id;
        $group{$payment_loginid}{$currency}{amount} += $commission;
        push @{$group{$payment_loginid}{$currency}{ids}}, $deal_id;
    }

    return {error => 'No payment made'} unless (%group);

    my $commission_db = BOM::Database::CommissionDB::rose_db();
    # make payment
    my @fail;
    my @updated;
    foreach my $payment_loginid (keys %group) {
        my $client = BOM::User::Client->new({loginid => uc $payment_loginid});
        unless ($client) {
            push @fail, $payment_loginid, 'Unknown payment id';
            next;
        }

        foreach my $currency (keys $group{$payment_loginid}->%*) {
            # There's a chance where affiliate payment details are being updated after the commission is being calculated with the old target currency.
            # In this case, we will do the conversion
            my $commission_amount = $group{$payment_loginid}{$currency}{amount};
            if ($client->currency ne $currency) {
                $commission_amount = convert_currency($commission_amount, $currency, $client->currency, 86500);
            }

            try {
                my $payment_date = Date::Utility->new;
                my $account      = $client->set_default_account($currency);

                my $payment_params = {
                    account_id           => $account->id,
                    amount               => financialrounding('price', $client->currency, $commission_amount),
                    payment_gateway_code => 'affiliate_reward',
                    payment_type_code    => 'affiliate_reward',
                    staff_loginid        => 'commission-manual-pay',
                    status               => 'OK',
                    remark               => sprintf("Payment from DerivX %s-%s", $payment_date->day_of_month, $payment_date->month_as_string),
                };

                # commission could be less than 1 cent and we can't make 0.00 payment, hence we're skipping it here.
                if ($payment_params->{amount} <= 0) {
                    push @fail, $payment_loginid, sprintf("aggregated commission is less than 1 cent [%s].", $commission_amount);
                    next;
                }

                my @bind_params = (
                    @$payment_params{
                        qw/account_id amount payment_gateway_code payment_type_code
                            staff_loginid payment_time transaction_time status
                            remark transfer_fees quantity source/
                    },
                    undef,    # child table
                    undef,    # transaction details
                );
                # perform transaction
                $account->db->dbic->txn(
                    ping => sub {
                        my $txn = $_->selectrow_hashref("SELECT t.* from payment.add_payment_transaction(?,?,?,?,?,?,?,?,?,?,?,?,?,?) t",
                            undef, @bind_params);
                        # update commission records with txn id
                        my $deal_ids = join ',', $group{$payment_loginid}{$currency}{ids}->@*;
                        $deal_ids = '{' . $deal_ids . '}';
                        my $newly_updated = $commission_db->dbic->run(
                            ping => sub {
                                $_->selectall_hashref(q{SELECT * FROM transaction.update_commission_payment_id(?,?)},
                                    'deal_id', undef, $txn->{id}, $deal_ids);
                            });
                        push @updated, [$_, $txn->{id}] for keys %$newly_updated;
                    });
            } catch ($e) {
                push @fail, $payment_loginid, 'transaction failure [' . Dumper($e) . ']';
            }
        }
    }

    return {@fail ? (error => sprintf("Failed to pay [%s]", (join ', ', @fail))) : (), updated => \@updated};
}

=head2 update_commission_config

Update commssion config in app config

=over 4

=item + C<$args{provider}> - Affiliate provider (E.g. myaffiliate)
=item + C<$args{commission_type}> - type of commission scheme (E.g. spread or volume)
=item + C<$args{status}> - flag to enable or disable commission calculation
=item + C<$args{payment_status}> - flag to enable or disable automatic affiliate commission payment from the cron job

=back

=cut

sub update_commission_config {
    my $args = shift;

    return {error => 'provider is required'} unless $args->{provider};

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $out = {success => 1};
    try {
        $app_config->set({'quants.' . $args->{provider} . '_affiliate_commission.type.financial'      => $args->{commission_type_financial}});
        $app_config->set({'quants.' . $args->{provider} . '_affiliate_commission.type.synthetic'      => $args->{commission_type_synthetic}});
        $app_config->set({'quants.' . $args->{provider} . '_affiliate_commission.enable'              => $args->{status}});
        $app_config->set({'quants.' . $args->{provider} . '_affiliate_commission.enable_auto_payment' => $args->{payment_status}});
    } catch ($e) {
        $out = {error => sprintf('Failed to update config [%s]', $e)};
    }

    return $out;
}

1;
