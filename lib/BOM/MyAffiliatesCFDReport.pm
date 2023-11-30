package BOM::MyAffiliatesCFDReport;
use strict;
use warnings;
use Object::Pad;

class BOM::MyAffiliatesCFDReport {

    use BOM::Database::UserDB;
    use BOM::Database::ClientDB;
    use BOM::Database::CommissionDB;
    use BOM::Platform::Event::Emitter;
    use DataDog::DogStatsd::Helper qw(stats_event);
    use Date::Utility;
    use Syntax::Keyword::Try;
    use YAML::XS qw(LoadFile);
    use Time::Moment;
    use Path::Class;
    use Log::Any qw($log);
    use Net::SFTP::Foreign;
    use Brands;

    use constant CONFIG              => '/etc/rmg/third_party.yml';
    use constant CSV_FOLDER_LOCATION => '/var/lib/myaffiliates/';
    use constant NEW_REGISTRATIONS   => '_registrations_';
    use constant TRADING_ACTIVITY    => '_pl_';
    use constant COMMISSION          => '_commissions_';
    use constant FTP_PATH            => '/myaffiliates/bom/data/data2/';
    use constant DAYS_TO_STORE_CSVS  => 30;
    use constant RETRY_LIMIT         => 5;
    use constant BATCH_SIZE          => 1000;
    use constant WAIT_IN_SECONDS     => 30;

    my ($db, $processing_date, $processing_date_yyyy_mm_dd, %config, $queries, %contract_size);

    # In case of any error while generating the csv this flag becomes 1
    # Just to mention that there are errors to address to in the email without going into much detail
    my $generation_error = 0;

=head2 new

Defines the attributes of the class
Initializes the database connections

=over 4

=item C<args{date}> - Date for which the report is to be generated

=item C<args{brand}> - Brand for which the report is to be generated, used for the csv file name

=item C<args{platform}> - Platform for which the report is to be generated, used for the database queries

=item C<args{test_run}> - Flag to indicate if the report is to be generated for testing purposes

=back

=cut

    BUILD(%args) {

        $db = {
            userdb       => BOM::Database::UserDB::rose_db(),
            clientdb     => BOM::Database::ClientDB->new({broker_code => 'CR'})->db,
            commissiondb => BOM::Database::CommissionDB::rose_db()};

        my $temp_config = LoadFile(CONFIG)->{myaffiliates};
        %config = %$temp_config;

        $processing_date                        = Date::Utility->new($args{date});
        $processing_date_yyyy_mm_dd             = $processing_date->date_yyyymmdd;
        $config{platform}                       = $args{platform} or die 'Platform not specified';
        $config{brand}                          = $args{brand}    or die 'Brand not specified';
        $config{test_run}                       = $args{test_run};
        $config{display_name}                   = $args{brand_display_name} or die 'Brand display name not specified';
        $config{sftp_path}                      = FTP_PATH . $config{brand} . '/';
        $config{csv_folder_location}            = CSV_FOLDER_LOCATION . $args{brand} . '/';
        $config{new_registrations_csv_filename} = $args{brand} . NEW_REGISTRATIONS . $processing_date_yyyy_mm_dd . '.csv';
        $config{trading_activity_csv_filename}  = $args{brand} . TRADING_ACTIVITY . $processing_date_yyyy_mm_dd . '.csv';
        $config{commission_csv_filename}        = $args{brand} . COMMISSION . $processing_date_yyyy_mm_dd . '.csv';

        $queries = {
            get_new_signups => {
                sql => 'SELECT creation_stamp, loginid, binary_user_id 
                          FROM users.get_real_loginids_timeframe(?, ?, ?, ?)',
                params => [qw(platform start_processing_date end_processing_date batch_size)],
                paging => 1,
                db     => 'userdb'
            },
            get_daily_deposits => {
                sql => 'SELECT transaction_time, account_id, amount
                          FROM payment.get_all_transfers_sum_timeframe(?, ?, ?, ?)',
                params => [qw(start_processing_date end_processing_date platform batch_size)],
                paging => 1,
                db     => 'clientdb'
            },
            get_first_deposit_and_date => {
                sql => 'SELECT *
                          FROM payment.get_first_transfer(?, ?)',
                params => [qw(loginid platform)],
                paging => 0,
                db     => 'clientdb'
            },
            get_total_volume => {
                sql => 'SELECT mapped_symbol, volume 
                          FROM transaction.commission 
                         WHERE 
                               affiliate_client_id = ? 
                           AND provider = ?::affiliate.client_provider
                           AND calculated_at >= ? 
                           AND calculated_at < ?',
                params => [qw(loginid platform start_processing_date end_processing_date)],
                paging => 0,
                db     => 'commissiondb'
            },
            get_binary_user_id => {
                sql => 'SELECT id 
                          FROM users.get_user_by_loginid(?)',
                params => [qw(loginid)],
                paging => 0,
                db     => 'userdb'
            },
            get_commissions => {
                sql => 'SELECT affiliate_client_id, SUM(commission_amount)
                          FROM transaction.get_commission_by_affiliate(?, $$myaffiliate$$, false, ?, NULL)
                         WHERE payment_id IS NOT NULL
                         GROUP BY affiliate_client_id',
                params => [qw(platform start_processing_date)],
                paging => 0,
                db     => 'commissiondb'
            },
            get_myaffiliate_token_and_residence => {
                sql => 'SELECT myaffiliates_token, residence 
                          FROM betonmarkets.client 
                         WHERE 
                               myaffiliates_token != $$$$ 
                           AND binary_user_id = ? LIMIT 1',
                params => [qw(binary_user_id)],
                paging => 0,
                db     => 'clientdb'
            }};

    }

=head2 execute

Main method to generate the csv files and send them via sftp

=cut

    method execute {

        $log->infof('Generating MyAffiliate reports for %s', $config{display_name});

        my $new_registrations_csv_content        = $self->new_registration_csv;
        my $new_registrations_csv_export_result  = $self->export_csv($config{new_registrations_csv_filename}, $new_registrations_csv_content);
        my $trading_activity_csv_content         = $self->trading_activity_csv;
        my $trading_activity_csv_export_result   = $self->export_csv($config{trading_activity_csv_filename}, $trading_activity_csv_content);
        my $commission_csv_content               = $self->commission_csv;
        my $commission_csv_export_result         = $self->export_csv($config{commission_csv_filename}, $commission_csv_content);
        my $new_registrations_csv_sending_result = 0;
        my $trading_activity_csv_sending_result  = 0;
        my $commission_csv_sending_result        = 0;
        my @not_send_csvs                        = ();
        my @not_generated_csvs                   = ();
        my @attachments;

        if ($new_registrations_csv_export_result) {
            $log->info('New registrations csv generated');
            push @attachments, $config{csv_folder_location} . $config{new_registrations_csv_filename};
            $new_registrations_csv_sending_result = $self->send_csv_via_sftp($config{new_registrations_csv_filename}, 'registrations')
                unless ($config{test_run});
            push @not_send_csvs, 'New Reigistrations' unless ($new_registrations_csv_sending_result);
        } else {
            $log->error('New registrations not csv generated');
            push @not_generated_csvs, 'New Registrations';
        }

        if ($trading_activity_csv_export_result) {
            $log->info('Trading activity csv generated');
            push @attachments, $config{csv_folder_location} . $config{trading_activity_csv_filename};
            $trading_activity_csv_sending_result = $self->send_csv_via_sftp($config{trading_activity_csv_filename}, 'activity')
                unless ($config{test_run});
            push @not_send_csvs, 'Trading Activity' unless ($trading_activity_csv_sending_result);

        } else {
            $log->error('Trading activity csv not generated');
            push @not_generated_csvs, 'Trading Activity';
        }

        if ($commission_csv_export_result) {
            $log->info('Commissions csv generated');
            push @attachments, $config{csv_folder_location} . $config{commission_csv_filename};
            $commission_csv_sending_result = $self->send_csv_via_sftp($config{commission_csv_filename}, 'commissions')
                unless ($config{test_run});
            push @not_send_csvs, 'Commissions' unless ($commission_csv_sending_result);

        } else {
            $log->error('Commissions csv not generated');
            push @not_generated_csvs, 'Commissions';
        }

        if (@not_generated_csvs) {
            stats_event(
                'MyAffiliatesCFDReport',
                'Error in generating ' . $config{display_name} . 'reports: ' . join(', ', @not_generated_csvs),
                {alert_type => 'error'});
        }

        if (@not_send_csvs) {
            stats_event(
                'MyAffiliatesCFDReport',
                'Error in sending ' . $config{display_name} . 'reports: ' . join(', ', @not_send_csvs),
                {alert_type => 'error'});
        }

        my @html_lines = (
            "<html>",
            "<body>",
            "<h2>CSV Files Generation Report</h2>",
            "<p>Generated Files:</p>",
            "<ul>",
            "<li>New Registrations: " . ($new_registrations_csv_export_result ? "Generated" : "Not Generated") . "</li>",
            "<li>Trading Activity: " .  ($trading_activity_csv_export_result  ? "Generated" : "Not Generated") . "</li>",
            "<li>Comissions: " .        ($commission_csv_export_result        ? "Generated" : "Not Generated") . "</li>",
            "</ul>",
            "<p>Sent Files:</p>",
            "<ul>",
            "<li>New Registrations: " . ($new_registrations_csv_sending_result ? "Sent" : "Not Sent") . "</li>",
            "<li>Trading Activity: " .  ($trading_activity_csv_sending_result  ? "Sent" : "Not Sent") . "</li>",
            "<li>Comissions: " .        ($commission_csv_sending_result        ? "Sent" : "Not Sent") . "</li>",
            "</ul>",
            "<ul>",
            "<li>"
                . ($generation_error ? "There was a problem while generating the reports, please check the logs" : "Generated without any errors")
                . "</li>",
            "</ul>"
        );

        my $brand = Brands->new();
        BOM::Platform::Event::Emitter::emit(
            'send_email',
            {
                from                  => $brand->emails('system'),
                to                    => $brand->emails('trading_ops'),
                subject               => $config{display_name} . ' daily reports sent to MyAffiliates ',
                email_content_is_html => 1,
                message               => \@html_lines,
                attachment            => \@attachments
            });

        $self->delete_old_csvs;
    }

=head2 new_registration_csv

Gathers the DerivX clients who have registered on the previous day
Checks if the gathered client have a myaffiliates token
Generates the csv file contents for new registrations in one string

=cut

    method new_registration_csv {
        $log->info('Generating new_registration_csv...');
        my $registration_table = "Date," . $config{display_name} . "AccountNumber,Token,ISOCountry\n";

        my $clients = $self->db_query('get_new_signups', {});

        foreach my $user (@$clients) {
            try {
                my ($creation_stamp, $loginid, $binary_user_id) = @$user;

                my $affiliate_token_and_residence =
                    $self->db_query('get_myaffiliate_token_and_residence', {binary_user_id => $binary_user_id})->[0] || [];
                my ($token, $residence) = @$affiliate_token_and_residence;
                next unless $token;
                $registration_table .= join(',', ($processing_date_yyyy_mm_dd, $loginid, $token, uc($residence))) . "\n";
            } catch ($e) {
                $log->errorf('Error on new_registration_csv: [%s]', $e);
                stats_event("MyAffiliatesCFDReport", "Error on new_registration_csv " . $user->[0] . ": [$e]", {alert_type => 'error'});
                $generation_error = 1;
            }
        }

        return $registration_table;
    }

=head2 trading_activity_csv

Gathers the DerivX clients who have traded on the previous day,
their sum of deposits and withdrawals, the first deposit amount and the first deposit date.
Checks if the gathered client have a myaffiliates token to get only the relevant clients
Generates the csv file contents for trading activity in one string

=cut

    method trading_activity_csv {
        $log->info('Generating trading_activity_csv...');

        # This is the header of the csv file
        my $trading_activity_table = "Date," . $config{display_name} . "AccountNumber,DailyVolume,DailyCountOfDeals,DailyBalance,FirstDeposit\n";

        # This gives the Daily amount of deposit and withdrawal, first deposit and first deposit date
        my $trading_activity = $self->db_query('get_daily_deposits', {});

        foreach my $row (@$trading_activity) {
            try {
                my ($transaction_time, $loginid, $daily_amount) = @$row;

                my $first_deposit_and_date = $self->db_query('get_first_deposit_and_date', {loginid => $loginid})->[0] || [];

                my ($first_deposit, $first_payment_date) = @$first_deposit_and_date;
                $first_deposit = 0 unless Date::Utility->new($first_payment_date)->days_since_epoch eq $processing_date->days_since_epoch;

                my $binary_user_id = $self->db_query('get_binary_user_id', {loginid => $loginid})->[0]->[0];

                # Get the token and residence
                my $affiliate_token_and_residence = $self->db_query('get_myaffiliate_token_and_residence', {binary_user_id => $binary_user_id});
                my $myaffiliates_token            = $affiliate_token_and_residence->[0]->[0];

                # Filter out clients who are not registered with myaffiliates
                if (defined $myaffiliates_token) {

                    # This gives the total volume and number of deals
                    my $deals = $self->db_query('get_total_volume', {loginid => $loginid});

                    my $count_of_deals = scalar @$deals;
                    my $total_volume   = 0;

                    # Lot size = volume / contract size
                    foreach my $deal (@$deals) {
                        my ($symbol, $volume) = @$deal;
                        my $contract_size = $self->db_query('get_symbol_contract_size', {symbol => $symbol});
                        $total_volume += $volume / $contract_size if $contract_size;
                    }

                    $trading_activity_table .=
                        join(',', ($processing_date_yyyy_mm_dd, $loginid, $total_volume, $count_of_deals, $daily_amount, $first_deposit)) . "\n";
                }
            } catch ($e) {
                $log->errorf('Error on trading_activity_csv: [%s]', $e);
                stats_event("MyAffiliatesCFDReport", "Error on trading_activity_csv " . $row->[0] . ": [$e]", {alert_type => 'error'});
                $generation_error = 1;
            }
        }

        return $trading_activity_table;
    }

=head2 commission_csv

The comission earned by the partners (IB) for a given day
Generates the csv file contents for commissions in one string

=cut

    method commission_csv {
        $log->info('Generating commission_csv...');

        my $commissions_table = "Date," . $config{display_name} . "AccountNumber,Amount\n";

        my $commissions = $self->db_query('get_commissions', {});

        foreach my $row (@$commissions) {
            my ($loginid, $commission) = @$row;
            $commissions_table .= join(',', ($processing_date_yyyy_mm_dd, $loginid, $commission)) . "\n";
        }

        return $commissions_table;
    }

=head2 db_query

Queries the database for the given query and parameters

=over 4

=item * C<$query> - The name of the query to be executed

=item * C<$params> - The parameters to be passed to the query

=back

Returns the result of the query

=cut

    method db_query ($query, $params) {

        if ($query eq 'get_symbol_contract_size') {

            return $contract_size{$params->{symbol}} if $contract_size{$params->{symbol}};
            try {
                my $db_contract_size = $db->{commissiondb}->dbic->run(
                    fixup => sub {
                        $_->selectrow_hashref(
                            'SELECT contract_size 
                               FROM affiliate.commission 
                              WHERE mapped_symbol = ?',
                            undef, $params->{symbol});
                    });

                if (not defined $db_contract_size->{contract_size}) {
                    $log->errorf('No contract size found for symbol %s', $params->{symbol});
                    stats_event("MyAffiliatesCFDReport", "No contract size found for symbol " . $params->{symbol}, {alert_type => 'error'});
                    $generation_error = 1;
                    return 0;
                }
                $contract_size{$params->{symbol}} = $db_contract_size->{contract_size};
                return $db_contract_size->{contract_size};

            } catch ($e) {
                $log->errorf('Error on get_symbol_contract_size: [%s]', $e);
                stats_event("MyAffiliatesCFDReport", "Error on get_symbol_contract_size", {alert_type => 'error'});
                $generation_error = 1;
                return 0;
            }
        }

        my $retries          = 0;
        my $query_parameters = {
            loginid               => $params->{loginid},
            binary_user_id        => $params->{binary_user_id},
            symbol                => $params->{symbol},
            start_processing_date => $processing_date->db_timestamp,
            end_processing_date   => $processing_date->plus_time_interval('1d')->db_timestamp,
            platform              => $config{platform},
            batch_size            => BATCH_SIZE
        };

        my @db_params;
        my $results = [];

        if ($queries->{$query}->{paging}) {
            my $record_batch = [];

            do {
                try {
                    # Here the first column is taken for paging purposes, timestamp type of data
                    $query_parameters->{end_processing_date} = $record_batch->[-1]->[0] if scalar(@$record_batch);
                    @db_params                               = map { $query_parameters->{$_} } @{$queries->{$query}->{params}};
                    $record_batch                            = $db->{$queries->{$query}->{db}}->dbic->run(
                        fixup => sub {
                            $_->selectall_arrayref($queries->{$query}->{sql}, undef, @db_params);
                        }) || [];

                    push @$results, @$record_batch;
                    $retries = 0;

                } catch ($e) {
                    $log->errorf('Error on query %s: [%s]', $query, $e);
                    stats_event("MyAffiliatesCFDReport", "Error on query $query", {alert_type => 'error'});
                    $generation_error = 1;
                    $retries++;
                    sleep WAIT_IN_SECONDS unless $retries == RETRY_LIMIT;
                }
            } while (scalar(@$record_batch) >= BATCH_SIZE or ($retries > 0 and $retries < RETRY_LIMIT));

            return $results;
        } else {
            do {
                try {
                    @db_params = map { $query_parameters->{$_} } @{$queries->{$query}->{params}};
                    $results   = $db->{$queries->{$query}->{db}}->dbic->run(
                        fixup => sub {
                            $_->selectall_arrayref($queries->{$query}->{sql}, undef, @db_params);
                        }) || [];

                    return $results;
                } catch ($e) {
                    $log->errorf('Error on query %s: [%s]', $query, $e);
                    stats_event("MyAffiliatesCFDReport", "Error on query $query", {alert_type => 'error'});
                    $generation_error = 1;
                    $retries++;
                    sleep WAIT_IN_SECONDS unless $retries == RETRY_LIMIT;
                }
            } while ($retries < RETRY_LIMIT);
            return [];
        }

    }

=head2 export_csv

Exports the csv file to the csv folder

=over 4

=item C<$csv_filename> - the name of the csv file

=item C<$csv_data> - the data to be written to the csv file

=back

Returns the csv filename

=cut

    method export_csv ($csv_filename, $csv_data) {
        $log->infof('Exporting %s', $csv_filename);
        my $csv_full_path_and_filename = $config{csv_folder_location} . $csv_filename;

        try {

            # delete the file if it exists
            if (-e $csv_full_path_and_filename) {
                unlink $csv_full_path_and_filename or die "Could not delete file '$csv_full_path_and_filename' $!";
            }

            # create the csv file
            open my $fh, '>', $csv_full_path_and_filename or die "Could not open file '$csv_full_path_and_filename' $!";
            print $fh $csv_data;
            close $fh;

            $log->infof('Created csv report: %s', $csv_full_path_and_filename);
            return 1;

        } catch ($e) {
            $log->errorf('Could not create csv report: %s [%s]', $csv_full_path_and_filename, $e);
            return 0;
        }

    }

=head2 send_csv_via_sftp

Sends the csv file to the sftp server

=over 4

=item C<$csv_filenames> - the name of the csv file to be sent

=item C<$folders> - the folder to be created on the sftp server

=back

=cut

    method send_csv_via_sftp ($csv_filename, $folder) {
        my $succeed = 0;
        for (my $try = 1; $try < RETRY_LIMIT and not $succeed; $try++) {
            try {

                my $sftp = Net::SFTP::Foreign->new(
                    $config{sftp_host},
                    user                       => $config{sftp_username},
                    password                   => $config{sftp_password},
                    port                       => $config{sftp_port},
                    asks_for_username_at_login => 'auto'
                ) or die "Cannot connect to: " . $config{sftp_host} . " $@";
                $log->infof('Connected to: %s', $config{sftp_host});

                my $local_filepath  = $config{csv_folder_location} . $csv_filename;
                my $remote_filepath = $config{sftp_path} . $folder . '/' . $csv_filename;

                $log->infof('Uploading file: %s to %s', $local_filepath, $remote_filepath);

                $sftp->put($local_filepath, $remote_filepath);
                if ($sftp->error) {
                    $log->errorf('Can\'t upload %s to %s: [%s]', $local_filepath, $remote_filepath, $sftp->error);
                    stats_event(
                        "MyAffiliatesCFDReport",
                        "Error uploading file $local_filepath to $remote_filepath: " . $sftp->error,
                        {alert_type => 'error'});
                } else {
                    $log->infof('File %s uploaded sucessfully to %s', $local_filepath, $remote_filepath);
                    stats_event("MyAffiliatesCFDReport", "File uploaded successfully: $local_filepath to $remote_filepath", {alert_type => 'info'});
                    $succeed = 1;
                }

                $sftp->disconnect;

            } catch ($e) {
                sleep WAIT_IN_SECONDS;
                $log->errorf('Attempt to upload files failed: [%s]', $e);
                stats_event("MyAffiliatesCFDReport", "Attempt to upload files failed", {alert_type => 'error'});
            }
        }
        return $succeed;
    }

=head2 delete_old_csvs

Deletes the csv files older than the number of days specified in DAYS_TO_STORE_CSVS

=cut

    method delete_old_csvs {
        try {
            my $dir   = dir($config{csv_folder_location});
            my @files = $dir->children;
            foreach my $file (@files) {
                my $file_age     = $file->stat->mtime;
                my $current_time = time;
                my $diff         = $current_time - $file_age;
                if ($diff > (DAYS_TO_STORE_CSVS * 24 * 60 * 60)) {
                    $log->infof('Deleting old csv file: %s', $file->basename);
                    $file->remove;
                }
            }
        } catch ($e) {
            $log->errorf('Failed to delete old myaffiliates csv reports: %s', $e);
            stats_event("MyAffiliatesCFDReport", "Failed to delete old myaffiliates csv reports", {alert_type => 'error'});
        }
    }

}

1;
