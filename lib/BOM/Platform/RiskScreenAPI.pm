package BOM::Platform::RiskScreenAPI;

use strict;
use warnings;
use feature qw(state);
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
use List::Util qw(first all uniq);

use BOM::Config;
use BOM::Database::UserDB;
use BOM::User::RiskScreen;
use BOM::User;

=head2 api

Get a Riskscreen API client object.

=cut

sub api {
    state $api;
    return $api if $api;

    my $loop   = IO::Async::Loop->new;
    my $config = BOM::Config::third_party()->{risk_screen};

    $loop->add(
        $api = WebService::Async::RiskScreen->new(
            host    => $config->{api_url} // 'dummy',
            api_key => $config->{api_key} // 'dummy',
            port    => $config->{port},
            timeout => 120
        ));

    return $api;
}

=head2 dbic

Get a connection to user database.

=cut

sub dbic {
    return BOM::Database::UserDB::rose_db()->dbic;
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
    my ($interface_reference) = @_;

    my $broker_codes = join '|', LandingCompany::Registry::all_broker_codes;
    $interface_reference //= '';
    $interface_reference =~ qr/(($broker_codes)\d+)/;
    my $loginid = $1;
    return undef unless ($loginid);

    return BOM::User->new(loginid => $loginid);
}

=head2 get_new_riskscreen_customers

Fetch the list of RiskScreen customers for which RiskScreen details should be updated,
including: 

=over 1

=item - customer with no record in our database

=item - those with I<requested> status

=item - those with I<client_entity_id> changed

=back

It returns an array of customer interface references.

=cut

async sub get_new_riskscreen_customers {
    # fetch all customers and group by user id
    my %user_data;
    my $constants = constants();
    for my $broker_code (LandingCompany::Registry::all_broker_codes) {
        my $customers = await api->client_entity_search(
            search_string => $broker_code,
            search_on     => $constants->{SearchOn}->{InterfaceReference},
            search_type   => $constants->{SearchType}->{Contains},
            search_status => $constants->{SearchStatus}->{Both},
        );
        for my $customer (@$customers) {
            my $user = get_user_by_interface_reference($customer->{interface_reference});
            next unless $user;

            $customer->{user}   = $user;
            $customer->{status} = lc(delete $customer->{status_name});

            push $user_data{$user->id}->@*, $customer;
        }
    }

    my @customer_ids;
    # There are some users with more than one RiskScreen customers.dd
    # TODO: It's better to remove redundant customers from RiskScreen server.
    for my $user_id (sort keys %user_data) {
        my @customers = $user_data{$user_id}->@*;

        # Tyy to pick the earliest active customer
        @customers = sort { $b->{date_added} cmp $a->{date_added} } @customers;
        my $selected_customer = (first { $_->{status} eq 'active' } @customers) // $customers[0];

        my $user            = delete $selected_customer->{user};
        my $old_data        = $user->risk_screen;
        my $customer_is_new = !$old_data || $old_data->status eq 'requested' || $old_data->client_entity_id != $selected_customer->{client_entity_id};

        $user->set_risk_screen($selected_customer->%*);
        push @customer_ids, $selected_customer->{interface_reference} if $customer_is_new;
    }

    @customer_ids = sort(@customer_ids);
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
    my @customer_ids = @_;

    await fmap_void(
        async sub {
            my ($interface_ref) = @_;

            my $customer_data = {interface_reference => $interface_ref};

            # retrieve matching details
            my $match_data = await api->client_entity_getdetail(interface_reference => $interface_ref);

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
            my $user = get_user_by_interface_reference($interface_ref);
            $user->set_risk_screen(%$customer_data);
        },
        foreach    => \@customer_ids,
        concurrent => 4
    );

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
    my $last_update_date = shift;

    # Empty update-date means that all custemers were new.
    # Their match details are already fetched.
    return () unless $last_update_date;

    my $start_date = Date::Utility->new($last_update_date);
    my $today      = Date::Utility->new;

    return () if $today->is_before($start_date);

    my %customers;
    await fmap_void(
        async sub {
            my ($days) = @_;

            my $date    = $start_date->plus_time_interval("${days}d");
            my $matches = await api->report_match_data_by_day(date => $date->date);

            for my $match (@$matches) {
                my $id = $match->{client_entity_id};
                next if $customers{$id};

                # if customer does not exist in out databse, it will be skipped.
                my ($riskscreen) = BOM::User::RiskScreen->find(client_entity_id => $id);
                next unless $riskscreen;

                $customers{$id} = $riskscreen;
            }
        },
        foreach    => [0 .. $today->days_between($start_date)],
        concurrent => 1
    );

    my @customer_ids = map { $_->{interface_reference} } values %customers;
    return @customer_ids;
}

=head2 sync_all_customers

Fetches all new data from RiskScreen and saves them to database. It is the top-most function of this module.

=cut

async sub sync_all_customers {
    my ($last_update_date) = dbic->run(
        fixup => sub {
            return $_->selectrow_array('select * from users.get_risk_screen_max_date_updated()');
        });

    my @new_customer_ids = await get_new_riskscreen_customers();
    await update_customer_match_details(@new_customer_ids);

    my @updated_customer_ids = await get_customers_with_new_matches($last_update_date);
    await update_customer_match_details(@updated_customer_ids);

    return {
        new_customers     => \@new_customer_ids,
        updated_customers => \@updated_customer_ids,
        last_update_date  => $last_update_date,
    };
}

1;
