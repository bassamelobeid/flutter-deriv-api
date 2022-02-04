package BOM::Platform::RiskScreenAPI;

use Moo;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Platform::RiskScreenAPI - subs for processing RiskScreen API data.

=head1 DESCRIPTION

This modules contains subs for performing complex tasks using RiskScreen API data,
like syncing the list of screened clients and getting updates about their matches.

=cut

use Future::AsyncAwait;
use Future::Utils qw(fmap_void fmap_concat);
use WebService::Async::RiskScreen;
use WebService::Async::RiskScreen::Utility qw(constants);
use LandingCompany::Registry;
use Data::Dumper;
use List::Util qw(first all uniq);
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Algorithm::Backoff;

use BOM::Config;
use BOM::Database::UserDB;
use BOM::User::RiskScreen;
use BOM::User;

use constant API_TIMEOUT            => 180;
use constant BACKOFF_INITIAL_DELAY  => 0.3;
use constant BACKOFF_MAX_DELAY      => 10;
use constant MAX_FAILURES_TOLERATED => 10;

=head2 update_all

A flag to forcefully update  all riskscreen customers on demand.

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

Get a Riskscreen API client object.

=cut

has api => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_api',
);

=head2 _build_api

Creates a Riskscreen API client object.

=cut

sub _build_api {
    my $loop   = IO::Async::Loop->new;
    my $config = BOM::Config::third_party()->{risk_screen};

    $loop->add(
        my $api = WebService::Async::RiskScreen->new(
            host    => $config->{api_url} // 'dummy',
            api_key => $config->{api_key} // 'dummy',
            port    => $config->{port},
            timeout => API_TIMEOUT
        ));

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

Parses an interface reference to extract loginid and converts an associated L<BOM::User> object.
It accepts the following argument:

=over 1

=item * C<interace_reference> - a string containing a RiskScreen customers B<Interface Reference>, the ID connecting RiskScreen customers to Deriv clients.

=back

It retruns a L<BOM::User> object.

=cut

sub get_user_by_interface_reference {
    my ($self, $interface_reference) = @_;

    my $broker_codes = join '|', LandingCompany::Registry->all_broker_codes;
    $interface_reference //= '';
    $interface_reference =~ qr/(($broker_codes)\d+)/;
    my $loginid = $1;
    return undef unless ($loginid);

    return BOM::User->new(loginid => $loginid);
}

=head2 get_udpated_riskscreen_customers

Fetch the list of RiskScreen customers for which RiskScreen details should be updated,
including:

=over 1

=item - customer with no record in our database

=item - those with I<requested> status

=item - those with I<client_entity_id> changed

=back

It returns an array of customer interface references.

=cut

async sub get_udpated_riskscreen_customers {
    my ($self) = @_;

    # fetch all customers and group by user id
    my %user_data;
    my $constants = constants();
    for my $broker_code (LandingCompany::Registry->all_broker_codes) {
        my $customers = await $self->api->client_entity_search(
            search_string => $broker_code,
            search_on     => $constants->{SearchOn}->{InterfaceReference},
            search_type   => $constants->{SearchType}->{Contains},
            search_status => $constants->{SearchStatus}->{Both},
        );

        $log->debugf('%d customers found for the broker %s', scalar @$customers, $broker_code);

        for my $customer (@$customers) {
            my $user = $self->get_user_by_interface_reference($customer->{interface_reference});

            my $user_id;

            if ($user) {
                $user_id = $user->{id};
            } else {
                # non-existing users should be skipped normally; but we can proceed for test.
                next unless $self->update_all;

                # set user_id to a unique negative value
                $user_id = -1 * $customer->{client_entity_id};
            }

            $customer->{status} = lc(delete $customer->{status_name});

            push $user_data{$user_id}->@*, $customer;
        }
    }

    my @customer_ids;
    # There are some users with more than one RiskScreen customers.
    # TODO: It's better to remove redundant customers from RiskScreen server.
    for my $user_id (sort keys %user_data) {
        my @customers = $user_data{$user_id}->@*;

        # Tyy to pick the earliest active customer
        @customers = sort { $b->{date_added} cmp $a->{date_added} } @customers;
        my $selected_customer = (first { $_->{status} eq 'active' } @customers) // $customers[0];

        # log skipped customers
        for my $customer (@customers) {
            $log->debugf(
                "Customer %s is skipped in favor of it's sibling %s",
                $customer->{interface_reference},
                $selected_customer->{interface_reference}) if $customer->{interface_reference} ne $selected_customer->{interface_reference};
        }

        my $user     = BOM::User->new(id => $user_id);
        my $old_data = $user ? $user->risk_screen : undef;
        my $customer_updated =
               $self->update_all
            || !$old_data
            || $old_data->status =~ qr/(requested|outdated)/
            || $old_data->client_entity_id != $selected_customer->{client_entity_id};

        $user->set_risk_screen($selected_customer->%*) if $user;
        push @customer_ids, $selected_customer->{interface_reference} if $customer_updated;
    }

    @customer_ids = sort(@customer_ids);
    @customer_ids = @customer_ids[0 .. $self->count - 1] if $self->count;
    return @customer_ids;
}

=head2 update_customer_match_details

Update the match details for the specified lists of RiskScreen customers.
It accepts one argument:

=over 4

=item * C<customer_ids> - an array of risk screen customer interface references.

=back

=cut

async sub update_customer_match_details {
    my ($self, @customer_ids) = @_;

    my $progress = 0;
    for my $interface_ref (@customer_ids) {
        my $user = $self->get_user_by_interface_reference($interface_ref);

        my $error;
        while (!$self->backoff->limit_reached) {
            try {
                my $customer_data = {interface_reference => $interface_ref};

                # retrieve matching details
                my $match_data = await $self->api->client_entity_getdetail(interface_reference => $interface_ref);

                $customer_data->{$_} = $match_data->{$_} // 0 for qw/match_potential_volume match_discounted_volume match_flagged_volume/;
                my @flags = uniq map { $_->{match_flag_category_name} // () } $match_data->{match_flagged}->@*;
                $customer_data->{flags} = [sort @flags];

                my @dates;
                for my $match_type (qw/potential discounted flagged/) {
                    push @dates, map { $_->{matched_date} // $_->{generated_date} } $match_data->{"match_$match_type"}->@*;
                }

                @dates = sort { ($b // '') cmp($a // '') } @dates;
                $customer_data->{date_updated} = $dates[0] if $dates[0];

                # save to database
                if ($user) {
                    $user->set_risk_screen(%$customer_data);
                    $log->debugf('Matches for the customer %s are saved to database', $interface_ref);
                } else {
                    $log->debugf(
                        'Matches for the customer %s were fetched, but were not saved to database; because it does not exist in our database',
                        $interface_ref);
                }

                last;
            } catch ($e) {
                $error = $e;
                $log->debugf('Error processing %s: %s retrying ...', $interface_ref, $error);
                my $loop = IO::Async::Loop->new;
                await $loop->delay_future(after => $self->backoff->next_value);
            }
        }
        if ($self->backoff->limit_reached) {
            $log->warnf('Failed to update matches for interface ref %s - %s', $interface_ref, Dumper $error);
            # users with status 'outdated' will be updated next time
            $user->set_risk_screen(status => 'outdated') if $user;

            $self->{failed_customers} //= 0;
            $self->{failed_customers} += 1;

            die 'Stopping the process because of too many failed cases' if $self->{failed_customers} > MAX_FAILURES_TOLERATED;
        }
        $self->backoff->reset_value;

        $log->debugf('%d/%d profiles synced so far', $progress, scalar @customer_ids) if (++$progress % 100 == 0);
    }

    return 1;
}

=head2 get_customers_with_new_matches

Gets the list of matches found from the last previously database updated date until today.
It will collect and return an array of client interface references.

=over 4

=item * C<last_update_date> - the last day customers were updated at.

=back

=cut

async sub get_customers_with_new_matches {
    my ($self, $last_update_date) = @_;

    # Empty update-date means that all custemers were new.
    # Their match details are already fetched.
    return () unless $last_update_date;

    my $start_date = Date::Utility->new($last_update_date);
    my $today      = Date::Utility->new;

    return () if $today->is_before($start_date);

    my $days_to_process = $today->days_between($start_date);
    $log->debugf('Started to sync matches since %s', $last_update_date);

    my %customers;
    my %skipped;
    my $total_matches = 0;
    for my $days (0 .. $days_to_process) {
        my $date = $start_date->plus_time_interval("${days}d");
        $log->debugf('Fetching matches for %s', $date->date);

        my $matches = await $self->api->report_match_data_by_day(date => $date->date);
        $total_matches += scalar @$matches;

        for my $match (@$matches) {
            my $id = $match->{client_entity_id};
            next if $customers{$id};

            # if customer does not exist in our database, it will be skipped.
            my ($riskscreen) = BOM::User::RiskScreen->find(client_entity_id => $id);
            unless ($riskscreen) {
                $skipped{client_entity_id} = 1;
                next;
            }

            $customers{$id} = $riskscreen;
        }
        last if $self->count && scalar(keys %customers) >= $self->count;
    }

    $log->debugf('Total matches found: %d',                                                                        $total_matches);
    $log->debugf("Matches for %d customers were skipped, because their entity ids were not found in our database", scalar(keys %skipped))
        if scalar(keys %skipped);

    my @customer_ids = map { $_->{interface_reference} } values %customers;
    return @customer_ids;
}

=head2 sync_all_customers

Fetches all new data from RiskScreen and saves them to database. It is the top-most function of this module.

=cut

async sub sync_all_customers {
    my ($self) = @_;

    my ($last_update_date) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select * from users.get_risk_screen_max_date_updated()');
        });
    $last_update_date //= Date::Utility->new->minus_time_interval('1d')->date;

    #new or updated riskscreen profiles
    my @new_customer_ids = await $self->get_udpated_riskscreen_customers();
    $log->debugf('%d riskscreen profiles will be updated', scalar @new_customer_ids);

    await $self->update_customer_match_details(@new_customer_ids);
    $log->debugf('Matches synced for the new and updated profiles');

    # profiles with new matches
    my @updated_customer_ids = await $self->get_customers_with_new_matches($last_update_date);
    $log->debugf('%d profiles with new matches found', scalar @updated_customer_ids);

    await $self->update_customer_match_details(@updated_customer_ids);

    $log->debugf('FINISHED');

    return 1;
}

1;
