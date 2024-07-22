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
use LandingCompany::Registry;
use Date::Utility;

use constant AFFILIATE_CHUNK_SIZE          => 300;
use constant AFFILIATE_BATCH_MONTHS        => 16;
use constant AFFILIATE_DEFAULT_LOOKUP_DATE => '2000-01-01';
use constant _ARCHIVAL_RESULT_KEY_TO_TITLE => {
    success                          => 'MT5 Technical Accounts Archived',
    main_account_ib_removal_success  => 'MT5 Main Account Archived - IB Comment Removed',
    failed                           => 'MT5 Technical Accounts Archival Failed',
    technical_account_balance_exists => 'MT5 Technical Accounts Archival Failed because of below accounts which has balance',
    main_account_ib_removal_failed   => 'MT5 Main Account Archival - IB Comment Removal Failed',
    account_not_found                => 'MT5 Account Not Found',
};

=head2 affiliate_sync_initiated


Initiates the affiliate sync process.

Will fetch the collection of loginids related to this affiliate, split them in chunks and process every chunk separately.

It takes the following arguments:

=over 4

=item * C<affiliate_id> - the id of the affiliate

=item * C<action> - sync or clear

=item * C<email> - email to notify when done

=back

Returns a L<Future> which resolves to C<undef>

=cut

async sub affiliate_sync_initiated {
    my ($data, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

    my $affiliate_id  = $data->{affiliate_id};
    my $deriv_loginid = $data->{deriv_loginid};

    my $client;
    $client = BOM::User::Client->new({loginid => $deriv_loginid}) if $deriv_loginid;

    my @loginids;
    try {
        @loginids = _get_clean_loginids(($client ? $client->date_joined : AFFILIATE_DEFAULT_LOOKUP_DATE), $affiliate_id)->@*;
    } catch ($e) {
        stats_event(
            'MyAffiliate Events - affiliate_sync_initiated',
            sprintf("%s : IB Sync event for Affiliate failed: %s", Date::Utility->new->datetime_ddmmmyy_hhmmss, $e),
            {alert_type => 'error'});

        my $action_text = $data->{action} eq 'clear' ? 'Untagging' : 'Synchronization to MT5';
        send_email({
                from                  => '<no-reply@binary.com>',
                to                    => join(',', $data->{email}, 'x-trading-ops@regentmarkets.com'),
                subject               => "Affiliate $affiliate_id $action_text",
                email_content_is_html => 1,
                message               => [
                    "<h3>$action_text for Affiliate $affiliate_id failed</h3>",
                    "<p>There was an error while getting the clients for the affiliate. Please contact BE</p>",
                ]});

        return undef;
    }

    while (my @chunk = splice(@loginids, 0, AFFILIATE_CHUNK_SIZE)) {
        my $args = {
            loginids     => [@chunk],
            affiliate_id => $affiliate_id,
            action       => $data->{action},
            email        => $data->{email},
            client       => $client,
            untag        => 0
        };

        # Don't fire a new event if this is the last batch, process it right away instead. Untag flag is on last batch to archive the affiliate accounts
        return await affiliate_loginids_sync({%$args, 'untag' => $data->{untag} // 0}, $service_contexts) unless @loginids;
        BOM::Platform::Event::Emitter::emit('affiliate_loginids_sync', $args);
    }

    if ($data->{untag}) {

        my $archival_result = $client ? _create_html_archival_report(await _archive_technical_accounts($client)) : ['<p>IB account not found</p>'];

        send_email({
                from                  => '<no-reply@binary.com>',
                to                    => join(',', $data->{email}, 'x-trading-ops@regentmarkets.com'),
                subject               => "Affiliate $affiliate_id Untagging",
                email_content_is_html => 1,
                message               => [
                    "<h1>Untagging for Affiliate $affiliate_id is finished</h1>",
                    '<h2>Action: sync agent with all clients</h2>',
                    '<p>The affiliate has no clients</p>',
                    '<br>', @$archival_result,
                ],
            });

        stats_event(
            'MyAffiliate Events - affiliate_sync_initiated',
            sprintf("%s : IB Untagging - archived with no clients", Date::Utility->new->datetime_ddmmmyy_hhmmss),
            {alert_type => 'info'});
    }

    return undef;

}

=head2 _create_html_archival_report

Adds HTML markup to the archival results and returns it.
Takes the following arguments:

=over 4

=item * C<result> - The result of the archival process

=back

Returns an arrayref of HTML strings

=cut

sub _create_html_archival_report {

    my $result = shift;
    return [
        '<h1>MT5 Main and Technical Accounts Archival</h1><br>',
        map {
            ('<h2>', _ARCHIVAL_RESULT_KEY_TO_TITLE->{$_}, '</h2><br><ul>', (map { ("<li>$_</li>") } sort @{$result->{$_}}), '</ul>',)
            }
            grep { @{$result->{$_}} > 0 }
            qw(success main_account_ib_removal_success failed  main_account_ib_removal_failed technical_account_balance_exists account_not_found)
    ];

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
    my ($data, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

    my ($affiliate_id, $loginids, $action, $client) = $data->@{qw/affiliate_id loginids action client/};

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

    my $action_text = $action eq 'clear' ? 'Untagging' : 'Synchronization to MT5';

    my $archival_result = [];
    if ($data->{untag}) {
        $archival_result = $client ? _create_html_archival_report(await _archive_technical_accounts($client)) : ['<p>IB account not found</p>'];
    }

    send_email({
            from                  => '<no-reply@binary.com>',
            to                    => join(',', $data->{email}, 'x-trading-ops@regentmarkets.com'),
            subject               => "Affiliate $affiliate_id $action_text",
            email_content_is_html => 1,
            message               => [
                "<h1>$action_text for Affiliate $affiliate_id is finished</h1>", '<br>',
                @$archival_result,                                               '<br>',
                '<h2>Action: sync agent with all clients</h2>',                  sort @results,
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
    my ($data, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

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
    my ($start_date, $affiliate_id) = @_;
    my $date_joined = Date::Utility->new($start_date);

    my $customers;
    my $my_affiliate = BOM::MyAffiliates->new(timeout => 300);

    my $months    = AFFILIATE_BATCH_MONTHS;
    my $date_from = Date::Utility->new->minus_months($months);
    my $date_to   = Date::Utility->new;

    while ($date_to->is_after($date_joined) || $date_to->is_same_as($date_joined)) {
        my $customers_batch = $my_affiliate->get_customers(
            AFFILIATE_ID => $affiliate_id,
            FROM_DATE    => $date_from->date_yyyymmdd,
            TO_DATE      => $date_to->date_yyyymmdd
        );

        my $error_str = $my_affiliate->errstr;
        if ($error_str) {
            if ($error_str =~ /Gateway Time-out/) {
                die "Myaffiliates API call failed with Gateway Time-out error" if $months <= 1;
                $my_affiliate->reset_errstr;
                $months /= 2;
                $date_from = Date::Utility->new->minus_months($months);
            } else {
                die "Myaffiliates API call failed with error: $error_str";
            }
        } else {
            push @$customers, @$customers_batch;
            $date_to   = $date_from->minus_time_interval('1d');
            $date_from = $date_from->minus_months($months);
        }

    }

    my $real_deriv_broker_codes = join('|', LandingCompany::Registry->all_real_broker_codes);
    return [
        uniq
            grep { m/^($real_deriv_broker_codes)?(?=\d+$)/ }
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
    my $client                    = shift;
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
