package BOM::Platform::LexisNexisAPI;

use Moo;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Platform::LexisNexisAPI - subs for processing LexisNexis API data.

=head1 DESCRIPTION

This modules contains subs for performing complex tasks using LexisNexis API data,
like syncing the list of screened clients and getting updates about their status.

=cut

use Future::AsyncAwait;
use Future::Utils qw(fmap_void fmap_concat);
use WebService::Async::LexisNexis;
use WebService::Async::LexisNexis::Utility qw(constants remap_keys);
use LandingCompany::Registry;
use Data::Dumper;
use List::Util qw(first all uniq);
use Log::Any   qw($log);
use Syntax::Keyword::Try;
use Algorithm::Backoff;

use BOM::Config;
use BOM::Database::UserDB;
use BOM::User::LexisNexis;
use BOM::User;

use constant API_TIMEOUT            => 1000;    # Increased the timeout due to the number of records in the production env
use constant BACKOFF_INITIAL_DELAY  => 0.3;
use constant BACKOFF_MAX_DELAY      => 10;
use constant MAX_FAILURES_TOLERATED => 10;

=head2 update_all

A flag to forcefully update  all LexisNexis customers on demand.

=cut

has update_all => (
    is   => 'rw',
    lazy => 1
);

=head2 count

Maximum new customers to process; useful for test purposes.

=cut

has count => (
    is   => 'rw',
    lazy => 1
);

=head2 api

Get a LexisNexis API client object.

=cut

has api => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_api',
);

=head2 _build_api

Creates a LexisNexis API client object.

=cut

sub _build_api {
    my $loop   = IO::Async::Loop->new;
    my $config = BOM::Config::third_party()->{lexis_nexis};

    $loop->add(
        my $api = WebService::Async::LexisNexis->new(
            host       => $config->{api_url} // 'dummy',
            api_key    => $config->{api_key} // 'dummy',
            port       => $config->{port},
            timeout    => API_TIMEOUT,
            auth_token => $config->{auth_token}));

    return $api;
}

=head2 dbic

Get a connection to user database.

=cut

has dbic => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_dbic',
);

=head2 _build_dbic

Creates a connection to user database.

=cut

sub _build_dbic {
    return BOM::Database::UserDB::rose_db()->dbic;
}

=head2 backoff

Returns an L<Algorithm::Backoff> instance.

=cut

has backoff => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_backoff',
);

=head2 _build_backoff

Creates an L<Algorithm::Backoff> instance.

=cut

sub _build_backoff {
    return Algorithm::Backoff->new(
        min => BACKOFF_INITIAL_DELAY,
        max => BACKOFF_MAX_DELAY
    );
}

=head2 get_user_by_interface_reference

Parses the loginid of the client to extract loginid and converts an associated L<BOM::User> object.
It accepts the following argument.

=over 1

=item * C<client_loginid> - a string containing a LexisNexis customers B<unique id> (loginid), the ID connecting LexisNexis customers to Deriv clients.

=back

It retruns a L<BOM::User> object.

=cut

sub get_user_by_interface_reference {
    my ($self, $client_loginid) = @_;

    my $broker_codes = join '|', LandingCompany::Registry->all_broker_codes;
    $client_loginid //= '';
    $client_loginid =~ qr/(($broker_codes)\d+)/;
    my $loginid = $1;
    return undef unless ($loginid);

    return BOM::User->new(loginid => $loginid);
}

=head2 sync_all_customers

Fetches all data from LexisNexis and saves them to database. It is the top-most function of this module.

=cut

async sub sync_all_customers {
    my ($self) = @_;

    my $constants = constants();

    my ($last_update_date) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select * from users.get_lexis_nexis_max_date_updated()');
        });

    $last_update_date //= Date::Utility->new('01-12-2022');
    # fetch all customers records from the LexisNexis server
    my @customers = await $self->get_all_client_records($last_update_date);
    $log->debugf('%d customers found', scalar @customers);

    for my $customer (@customers) {
        my $user;
        next unless ($customer->{record_details}->{additional_info});

        # The client id (ex: CR900001) is in the additional_info array
        for my $info (@{$customer->{record_details}->{additional_info}}) {
            $user = $self->get_user_by_interface_reference($info->{value}) if defined $info->{label} && $info->{label} eq "client_loginid";
            if ($user) {
                $customer->{client_loginid} = $info->{value};
                last;
            }
        }

        # Set result_id as alert_id
        $customer->{alert_id} = $customer->{result_id};

        my $user_id;

        if ($user) {
            $user_id = $user->{id};
        } else {
            # non-existing users should be skipped normally; but we can proceed for test.
            next unless $self->update_all;

            # set user_id to a unique negative value
            $user_id = -1 * $customer->{alert_id};
        }

        # Set the search date as the date_added
        $customer->{date_added} = $customer->{record_details}->{search_date};

        # Set the most recent date in the match list as the date_updated
        my @dates;
        push @dates, map { $_->{result_date} // $_->{date_modified} // $_->{entity_details}->{date_listed} } @{$customer->{watchlist}->{matches}};

        @dates = sort { ($b // '') cmp($a // '') } @dates;
        $customer->{date_updated} = $dates[0] if $dates[0];

        # Set the alert_status and the custom note for the profile
        for my $record_history (@{$customer->{record_details}->{record_state}->{history}}) {
            if ($record_history->{event} eq $constants->{Events}->{NewNote} && !exists $customer->{note}) {
                $customer->{note} = $record_history->{note};
            }
        }

        # Set the status of the alert
        my $alert_status = $customer->{record_details}->{record_state}->{status};

        if ($alert_status =~ /Undetermined/i) {
            $customer->{alert_status} = "undetermined";
        } elsif ($alert_status =~ /False Positive/i) {
            $customer->{alert_status} = "false positive";
        } elsif ($alert_status =~ /Positive Match/i) {
            $customer->{alert_status} = "positive match";
        } elsif ($alert_status =~ /Potential Match/i) {
            $customer->{alert_status} = "potential match";
        } elsif ($alert_status =~ /False Match_Config/i) {
            $customer->{alert_status} = "false match config";
        } else {
            $customer->{alert_status} = "open";
        }
        # check the user has previous data in the users.lexis_nexis table
        my $old_data = $user ? $user->lexis_nexis : undef;

        my $customer_updated =
               $self->update_all
            || !$old_data
            || $old_data->alert_status =~ qr/(requested|outdated)/
            || $old_data->alert_id != $customer->{alert_id}
            || exists $customer->{alert_status} && lc($old_data->alert_status) ne lc($customer->{alert_status});

        # if the custom note is not valid it will be ignored (not saved)
        delete $customer->{note}
            if defined $customer->{note} && !BOM::User::LexisNexis->validate_custom_text1($customer->{note});

        $user->set_lexis_nexis($customer->%*) if $user && $customer_updated;

    }

    $log->debugf('FINISHED');

    return 1;
}

=head2 get_jwt_token

Get the JWT token from the LexisNexis Bridger.
This token is used by other REST API endpoints for authorization

=cut

async sub get_jwt_token {
    my ($self) = @_;

    my $result = await $self->api->issue_jwt_token();
    my $access_token;
    $access_token = $result->{access_token} if $result->{access_token};
    return $access_token;
}

=head2 get_record_ids

Get record ids for the given client id or given run ids

=cut

async sub get_record_ids {
    my ($self, $auth_token, $params) = @_;

    my $result;

    try {
        $result = await $self->api->request_record_ids(
            run_ids    => $params->{run_ids},
            auth_token => $auth_token
        );
    } catch ($e) {
        #If the jwt token is expired generate a new one and recall the method
        if ($e->{http_code} == 401) {
            $auth_token = await $self->get_jwt_token();
            $_[1]       = $auth_token;                            # Updating the reference value
            $result     = await $self->api->request_record_ids(
                run_ids    => $params->{run_ids},
                auth_token => $auth_token
            );
        }
    }

    my $record_ids = $result->{record_i_ds} if $result->{record_i_ds};
    return $record_ids;
}

=head2 get_records

Get the alerts/records for given record ids

=cut

async sub get_records {
    my ($self, $auth_token, $record_ids) = @_;

    my $records;
    try {
        $records = await $self->api->request_records(
            record_ids => $record_ids,
            auth_token => $auth_token
        );
    } catch ($e) {
        #If the jwt token is expired generate a new one and call the method again
        if (exists $e->{http_code} && $e->{http_code} == 401) {
            $auth_token = await $self->get_jwt_token();
            $_[1]       = $auth_token;                         # Updating the reference value
            $records    = await $self->api->request_records(
                record_ids => $record_ids,
                auth_token => $auth_token
            );
        }
    }
    return $records;
}

=head2 get_runs_ids

Fetch all the run ids from the LexisNexis server
Runs are created when the search records are imported to the server

=cut

async sub get_runs_ids {
    my ($self, $auth_token, $date_end, $date_start) = @_;

    my $result;
    try {
        $result = await $self->api->request_runs_ids(
            auth_token => $auth_token,
            date_end   => $date_end,
            date_start => $date_start
        );
    } catch ($e) {
        #If the jwt token is expired generate a new one and call the method again
        if ($e->{http_code} == 401) {
            $auth_token = await $self->get_jwt_token();
            $_[1]       = $auth_token;                                                     # Updating the reference value
            $result     = await $self->api->request_runs_ids(auth_token => $auth_token);
        }
    }

    my @run_ids;
    $result = remap_keys('snake', $result);
    for my $run (@$result) {
        if ($run->{num_records_processed} > 0) {
            push(@run_ids, $run->{run_id});
        }
    }

    return \@run_ids;
}

=head2 get_all_client_records

Get all the alerts/records from the LexisNexis Server
Returns an array of records

=cut

async sub get_all_client_records {
    my ($self, $last_update_date) = @_;

    my $token = await $self->get_jwt_token();

    my $today      = Date::Utility->new;
    my $date_start = Date::Utility->new($last_update_date);
    return () if $today->is_before($date_start);

    my $days_to_process = $today->days_between($date_start);
    my $ids             = [];

    for my $days (0 .. $days_to_process) {
        my $date_end = $date_start->plus_time_interval("${days}d");
        $log->debugf('Fetching matches for %s', $date_end->date);
        my $run_ids = await $self->get_runs_ids($token, $date_end->date_yyyymmdd(), $date_start->date_yyyymmdd());

        @$ids       = (@$ids, @$run_ids) if (defined $run_ids);
        $date_start = $date_end;
    }

    # If the count variable is set, we only need to update that number records
    if ($self->count > 0 && scalar(@$ids) > $self->count) {
        $#{$ids} = $self->count - 1;
    }

    my @arr;
    # Maximum of 100 ids allowed as a input per an API call
    push @arr, [splice @$ids, 0, 100] while @$ids;

    my $record_ids;
    my $record_ids_list = [];

    for my $idList (@arr) {
        $record_ids       = await $self->get_record_ids($token, {run_ids => $idList}) unless scalar @$idList <= 0;
        @$record_ids_list = (@$record_ids_list, @$record_ids) if (defined $record_ids);
    }

    my @arr_record_ids_list;
    # Splicing the record ids list into 100 items per batch
    push @arr_record_ids_list, [splice @$record_ids_list, 0, 100] while @$record_ids_list;

    my $records;
    my @client_records;
    for my $list (@arr_record_ids_list) {
        $records = await $self->get_records($token, $list);
        for my $record (@$records) {
            push @client_records, $record;
        }
    }

    return @client_records;
}

1;
