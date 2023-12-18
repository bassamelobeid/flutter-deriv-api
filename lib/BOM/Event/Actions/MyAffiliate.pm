package BOM::Event::Actions::MyAffiliate;

use strict;
use warnings;

use Log::Any qw($log);

use Syntax::Keyword::Try;
use BOM::MyAffiliates;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Future::AsyncAwait;
use Future::Utils 'fmap1';
use BOM::MT5::User::Async;
use BOM::Event::Utility qw(exception_logged);
use BOM::Platform::Event::Emitter;
use List::Util                 qw(uniq);
use Path::Tiny                 qw(path);
use DataDog::DogStatsd::Helper qw(stats_event);
use Scalar::Util;

use constant AFFILIATE_CHUNK_SIZE => 300;

=head2 affiliate_sync_initiated


Initiates the affiliate sync process.

Will fetch the collection of loginids related to this affiliate, split them in chunks and process every chunk separately.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Returns a L<Future> which resolvs to C<undef>

=cut

async sub affiliate_sync_initiated {
    my ($data) = @_;
    my $affiliate_id = $data->{affiliate_id};

    my @loginids = _get_clean_loginids($affiliate_id)->@*;

    while (my @chunk = splice(@loginids, 0, AFFILIATE_CHUNK_SIZE)) {
        my $args = {
            loginids      => [@chunk],
            affiliate_id  => $affiliate_id,
            action        => $data->{action},
            email         => $data->{email},
            deriv_loginid => $data->{deriv_loginid},
            untag         => $data->{untag} // 0,
        };

        # Don't fire a new event if this is the last batch, process it right away instead
        return await affiliate_loginids_sync($args) unless @loginids;

        BOM::Platform::Event::Emitter::emit('affiliate_loginids_sync', $args);
    }

    return undef;
}

=head2 affiliate_loginids_sync

Process an affiliate loginids by chunks.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<loginids> - the chunk of loginids to be processed in this batch.

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Returns a L<Future> which resolves to C<undef>

=cut

async sub affiliate_loginids_sync {
    my ($data) = @_;
    my ($affiliate_id, $loginids, $action) = $data->@{qw/affiliate_id loginids action/};

    stats_event(
        'MyAffiliate Events - affiliate_loginids_sync',
        sprintf("%s : IB Sync event for Affiliate ID [%s]", Date::Utility->new->datetime_ddmmmyy_hhmmss, $affiliate_id),
        {alert_type => 'info'});

    my @results;
    for my $loginid (@$loginids) {
        try {
            my $result = await _populate_mt5_affiliate_to_client($loginid, $action eq 'clear' ? undef : $affiliate_id);
            push @results, @$result;
        } catch ($e) {
            push @results, "$loginid: an error occured: $e";
            exception_logged();
        }
    }

    my $archive_result = {};
    $archive_result = await _archive_technical_accounts($data->{deriv_loginid}) if $data->{untag};

    my $section_sep = '-' x 20;
    my @archive_report;
    push @archive_report, ($section_sep, 'MT5 Technical Accounts Archived', '~~~', (sort @{$archive_result->{success}}), '~~~')
        if exists $archive_result->{success} and @{$archive_result->{success}};
    push @archive_report, ($section_sep, 'MT5 Technical Accounts Archive Failed', '~~~', (sort @{$archive_result->{failed}}), '~~~')
        if exists $archive_result->{failed} and @{$archive_result->{failed}};

    push @archive_report,
        ($section_sep, 'MT5 Main Account - IB Comment Removed', '~~~', (sort @{$archive_result->{main_account_ib_removal_success}}), '~~~')
        if exists $archive_result->{main_account_ib_removal_success} and @{$archive_result->{main_account_ib_removal_success}};
    push @archive_report,
        ($section_sep, 'MT5 Main Account - IB Comment Removal Failed', '~~~', (sort @{$archive_result->{main_account_ib_removal_failed}}), '~~~')
        if exists $archive_result->{main_account_ib_removal_failed} and @{$archive_result->{main_account_ib_removal_failed}};
    push @archive_report, ($section_sep, 'MT5 Account Not Found', '~~~', (sort @{$archive_result->{account_not_found}}), '~~~')
        if exists $archive_result->{account_not_found} and @{$archive_result->{account_not_found}};
    push @archive_report,
        (
        $section_sep, 'MT5 Technical Accounts Archival Failed because of below accounts which has balance',
        '~~~', (sort @{$archive_result->{technical_account_balance_exists}}), '~~~'
        ) if exists $archive_result->{technical_account_balance_exists} and @{$archive_result->{technical_account_balance_exists}};

    send_email({
            from    => '<no-reply@binary.com>',
            to      => join(',', $data->{email}, 'x-trading-ops@regentmarkets.com'),
            subject => "Affiliate $affiliate_id " . ($data->{untag} ? 'untagging operation' : 'synchronization to mt5'),
            message => [
                ($data->{untag} ? 'Untag operation' : 'Synchronization to mt5') . " for Affiliate $affiliate_id is finished.",
                'Action: ' . ($action eq 'clear' ? 'remove agent from all clients.' : 'sync agent with all clients.'),
                $section_sep, (sort @results),
                @archive_report,
            ],
        });

    return undef;
}

=head2 bulk_affiliate_loginids_sync

Process an affiliate loginids by chunks in bulk of affiliate IDs.

It takes the following arguments:

=over 4

=item * C<affiliate_loginids> - hash of affiliate ids and its customers loginids

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Returns a L<Future> which resolves to C<undef>

=cut

async sub bulk_affiliate_loginids_sync {
    my ($data)             = @_;
    my $action             = $data->{action};
    my $affiliate_loginids = $data->{affiliate_loginids};

    my (@success, @errors, $affiliate_synced, @success_list, @message, $attachment);

    foreach my $affiliate_id (keys %{$affiliate_loginids}) {
        @success = ();
        for my $loginid (@{$affiliate_loginids->{$affiliate_id}}) {
            try {
                my $result = await _populate_mt5_affiliate_to_client($loginid, $action eq 'clear' ? undef : $affiliate_id);

                defined @$result[0] ? push(@errors, @$result) : push(@success, $loginid);

            } catch ($e) {
                push @errors, "$loginid: an error occured: $e";
                exception_logged();
            }
        }
        if (scalar @success > 0) {
            $affiliate_synced->{AffiliateID} = $affiliate_id;
            $affiliate_synced->{CustomerID}  = [@success];
            push @success_list, $affiliate_synced;
        }
    }

    stats_event(
        'MyAffiliate Events - bulk_affiliate_loginids_sync',
        sprintf(
            "%s : Bulk IB Sync event for Affiliate ID \n[%s]",
            Date::Utility->new->datetime_ddmmmyy_hhmmss,
            (join ", ", (map { $_ } keys %{$affiliate_loginids}))
        ),
        {alert_type => 'info'});

    push @message, '<h2>Bulk Affliate synchronization to MT5 summary for ' . $data->{processing_date} . '</h2><br>';

    if (scalar @success_list > 0) {
        push @message, "<h2>Successfull sync are listed in the CSV attachment below.</h2><br>";
        my $file_path = $data->{csv_output_folder} . 'bulk-affiliate-sync-' . $data->{processing_date} . '.csv';
        my @headers   = qw(AffiliateID CustomerID);
        $attachment = _generate_csv(\@headers, \@success_list, $file_path);
    }

    if (scalar @errors > 0) {
        push @message, "<h2>Errors</h2><br>";
        push(@message, $_ . "<br>") for @errors;
    }

    send_email({
        from    => '<no-reply@binary.com>',
        to      => $data->{email},
        subject => "Bulk Affliate synchronization to MT5",
        message => \@message,
        $attachment ? (attachment => $attachment) : (),
        email_content_is_html => 1,
    });

    return undef;
}

async sub _populate_mt5_affiliate_to_client {
    my ($loginid, $affiliate_id) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});
    return ["$loginid: not a valid loginid"] unless $client;

    if ($affiliate_id) {
        return ["Affiliate token not found for $loginid"] unless $client->myaffiliates_token;

        my $myaffiliates    = BOM::MyAffiliates->new(timeout => 300);
        my $myaffiliates_id = $myaffiliates->get_affiliate_id_from_token($client->myaffiliates_token);

        return ["Could not match the affiliate $affiliate_id based on the provided token '" . $client->myaffiliates_token . "'"]
            unless Scalar::Util::looks_like_number($myaffiliates_id)
            and $affiliate_id == $myaffiliates_id;
    }

    my $user       = $client->user;
    my @mt5_logins = $user->mt5_logins;

    my @results = await fmap1(
        async sub {
            my $mt5_login = shift;
            try {
                my $result = await _set_affiliate_for_mt5($user, $mt5_login, $affiliate_id);
                return defined $result ? "$loginid: account $mt5_login agent updated to $result" : undef;
            } catch ($e) {
                exception_logged();
                return "$loginid: account $mt5_login had an error: $e";
            }
        },
        foreach    => \@mt5_logins,
        concurrent => 2,
    );

    return [grep { defined } @results];
}

async sub _set_affiliate_for_mt5 {
    my ($user, $mt5_login, $affiliate_id) = @_;

    # Skip demo accounts
    return if $mt5_login =~ /^MTD/;

    my $user_details = await BOM::MT5::User::Async::get_user($mt5_login);

    return if $user_details->{group} =~ /^demo/;

    my $agent_id;
    if ($affiliate_id) {
        my $trade_server_id = BOM::MT5::User::Async::get_trading_server_key({login => $mt5_login}, 'real');
        ($agent_id) = $user->dbic->run(
            fixup => sub {
                $_->selectrow_array(q{SELECT * FROM mt5.get_agent_id(?, ?)}, undef, $affiliate_id, $trade_server_id);
            });
    }

    $agent_id //= 0;

    # no update needed
    return if $agent_id == ($user_details->{agent} // 0);

    delete $user_details->{color};
    await BOM::MT5::User::Async::update_user({
        %{$user_details},
        login => $mt5_login,
        agent => $agent_id,
    });

    return $agent_id;
}

sub _get_clean_loginids {
    my ($affiliate_id) = @_;
    my $my_affiliate   = BOM::MyAffiliates->new(timeout => 300);
    my $customers      = $my_affiliate->get_customers(AFFILIATE_ID => $affiliate_id);

    return [
        uniq
            grep { !/${BOM::User->MT5_REGEX}/ }
            map  { s/^deriv_//r }
            map  { $_->{CLIENT_ID} || () } @$customers
    ];
}

sub _generate_csv {
    my ($headers, $array_list, $file_path) = @_;
    my (@csv_rows);
    my $filename = path($file_path);
    my $file     = path($filename)->openw_utf8;
    my $csv      = Text::CSV->new({
        eol        => "\n",
        quote_char => undef
    });

    for my $result ($array_list->@*) {
        my @result_row;
        for my $header ($headers->@*) {
            push @result_row, $result->{$header};
        }
        push @csv_rows, \@result_row;
    }

    $csv->print($file, $headers);

    for my $row (@csv_rows) {
        my ($affiliate_id, $customers);
        for my $data_row (@$row) {
            if (ref($data_row) eq 'ARRAY') {
                $customers = join("|", @$data_row);
            } else {
                $affiliate_id = $data_row;
            }
        }
        my $data = sprintf('%s, %s', $affiliate_id, $customers);
        $csv->print($file, [$data]);
    }

    return $filename->canonpath;
}

async sub _archive_technical_accounts {
    my $deriv_loginid             = shift;
    my $client                    = BOM::User::Client->new({loginid => $deriv_loginid});
    my $affiliate_mt5_accounts_db = $client->user->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(q{SELECT * FROM mt5.list_user_accounts(?)}, {Slice => {}}, $client->user->id);
        });

    my %affiliate_mt5_accounts = map { 'MTR' . $_->{mt5_account_id} => $_ } @$affiliate_mt5_accounts_db;

    my %archive_result;
    $archive_result{success}                          = [];
    $archive_result{failed}                           = [];
    $archive_result{main_account_ib_removal_success}  = [];
    $archive_result{main_account_ib_removal_failed}   = [];
    $archive_result{account_not_found}                = [];
    $archive_result{technical_account_balance_exists} = [];
    my $eligible_to_archive = 1;

    foreach my $mt5_account (keys %affiliate_mt5_accounts) {
        my $user_data;
        try {
            $user_data = await BOM::MT5::User::Async::get_user($mt5_account);
            if ($user_data->{balance} != 0 && $affiliate_mt5_accounts{$mt5_account}{mt5_account_type} eq 'technical') {
                $eligible_to_archive = 0;
                push @{$archive_result{technical_account_balance_exists}}, $mt5_account;
            }
        } catch ($e) {
            my $error_code = '';
            $error_code = ' - ' . $e->{code} if ref $e eq 'HASH' and exists $e->{code};
            push @{$archive_result{account_not_found}}, $mt5_account . $error_code;
        }
    }

    if ($eligible_to_archive) {
        foreach my $mt5_account (keys %affiliate_mt5_accounts) {
            if ($affiliate_mt5_accounts{$mt5_account}{mt5_account_type} eq 'technical') {
                try {
                    await BOM::MT5::User::Async::user_archive($mt5_account);
                    push @{$archive_result{success}}, $mt5_account;
                } catch ($e) {
                    my $error_code = '';
                    $error_code = ' - ' . $e->{code} if ref $e eq 'HASH' and exists $e->{code};
                    push @{$archive_result{failed}}, $mt5_account . $error_code;
                }
            } elsif ($affiliate_mt5_accounts{$mt5_account}{mt5_account_type} eq 'main') {
                try {
                    my $user_detail = await BOM::MT5::User::Async::get_user($mt5_account);
                    $user_detail->{comment} = '';
                    await BOM::MT5::User::Async::update_user($user_detail);
                    push @{$archive_result{main_account_ib_removal_success}}, $mt5_account;
                    $client->user->dbic->run(
                        fixup => sub {
                            $_->do(q{SELECT mt5.remove_mt5_affiliate_accounts(?)}, undef, $client->user->id);
                        });
                } catch ($e) {
                    my $error_code = '';
                    $error_code = ' - ' . $e->{code} if ref $e eq 'HASH' and exists $e->{code};
                    push @{$archive_result{main_account_ib_removal_failed}}, $mt5_account . $error_code;
                }
            }
        }
    }
    return \%archive_result;
}

1;
