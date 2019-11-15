package BOM::RPC::v3::OTC;

=head1 NAME

BOM::RPC::v3::OTC - peer-to-peer "over-the-counter" payment support

=head1 DESCRIPTION

The OTC cashier is a system which allows buyers and sellers to handle the details
of payments outside our system. It acts as a marketplace for offers and orders.

=cut

use strict;
use warnings;

use JSON::MaybeUTF8 qw(:v1);
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::User::Client;
use BOM::Platform::Context qw (localize request);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::User;
use Try::Tiny;

use BOM::RPC::Registry '-dsl';

# Currently all functionality is restricted to users with
# valid accounts. There's little harm in allowing a list
# of orders or offers, but also no value to us in doing so.
requires_auth();

# Standard error codes for any OTC calls.
our %ERROR_MAP = do {
    # `make i18n` wants to see literal strings in `localize()` calls to decide
    # what to translate. We temporarily provide a no-op version so we can
    # populate our static definitions. We'll then run `localize` *again* on
    # each item when we want to send to a client.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        # System or country limitations
        OTCDisabled          => localize('The OTC cashier is currently disabled'),
        RestrictedCountry    => localize('This country is not enabled for OTC cashier functionality'),
        RestrictedCurrency   => localize('This currency is not enabled for OTC cashier functionality'),
        UnavailableOnVirtual => localize('OTC cashier functionality is not available on demo accounts'),
        # Client status
        NotLoggedIn      => localize('You are not logged in'),
        NoCurrency       => localize('You have not yet selected a currency for your account'),
        PermissionDenied => localize('You do not have permission for this action'),
        NotRegistered    => localize('You are not yet registered as an OTC agent'),
        AgentNotActive   => localize('This agent account is not currently active'),
        # Invalid data
        InvalidPaymentMethod => localize('This payment method is invalid'),
        NotFound             => localize('Not found'),
        MinimumNotMet        => localize('The minimum amount requirements are not met'),
        MaximumExceeded      => localize('This is above the maximum limit'),
        AlreadyInProgress    => localize('This cannot be cancelled since the order is already in progress'),
        # Actions after orders are complete
        OrderAlreadyComplete => localize('This order is already complete and no changes can be made'),
    );
};

our %MOCK_DATA = (
    agent => {
        1 => {
            name       => 'first agent',
            login_id   => 'CR100',
            status     => 'active',
            statistics => {
                total_orders    => 15,
                month_orders    => 15,
                success_rate    => 0.85,
                completion_time => 600,
            }
        },
        2 => {
            name     => 'second agent',
            status   => 'inactive',
            login_id => 'CR101',
        }
    },
    offer => [
        1 => {
            agent_id  => 1,
            type      => 'sell',
            min       => 10,
            max       => 100,
            remaining => 75,
            price     => 5.34,
            method    => 'cimb',
            currency  => 'MYR',
        },
        2 => {
            agent_id  => 1,
            type      => 'sell',
            min       => 10,
            max       => 100,
            remaining => 100,
            price     => 5.34,
            method    => 'grabpay',
            currency  => 'MYR',
        },
        3 => {
            agent_id  => 2,
            type      => 'sell',
            min       => 50,
            max       => 250,
            remaining => 150,
            price     => 5.32,
            method    => 'hsbc',
            currency  => 'MYR',
        }
    ],
    order => {
        1 => {
            login_id => 'CR102',
            offer_id => 1,
            amount   => 25,
        },
        2 => {
            login_id => 'CR103',
            offer_id => 2,
            amount   => 100,
        }
    },
);

=head2 otc_rpc

Helper function for wrapping error handling around our OTC-related RPC calls.

Takes the following parameters:

=over 4

=item * C<$method> - which method to expose, e.g. C<otc_order_create>

=item * C<$code> - the coderef to call

=back

C<$code> will be called with the following named parameters:

=over 4

=item * C<client> - the L<BOM::User::Client> instance

=item * C<account> - the L<BOM::User::Client::Account> instance

=item * C<app_config> - current app config as provided by L<BOM::Config::Runtime/app_config>

=item * C<params> - whatever parameters were passed through the RPC call

=back

Example usage:

 otc_rpc otc_order_create => sub { create_order($client, $params->{amount}) };

=cut

sub otc_rpc {
    my ($method, $code) = @_;
    return rpc $method => category => 'otc',
        sub {
        my $params = shift;
        try {
            my $app_config = BOM::Config::Runtime->instance->app_config;

            # Yes, we have two ways to disable - devops can shut it down if there
            # are problems, and payments/ops/QA can choose whether or not the
            # functionality should be exposed in the first place. The ->otc->enabled
            # check may be dropped in future once this is stable.
            die "OTCDisabled\n" if $app_config->system->suspend->otc;
            die "OTCDisabled\n" if $app_config->otc->enabled;

            # All operations require a valid client with active account
            my $client = $params->{client}
                or die "NotLoggedIn\n";

            die "UnavailableOnVirtual\n" if $client->is_virtual;

            my $acc = $client->default_account
                or die "NoCurrency\n";

            return $code->(
                client     => $client,
                account    => $acc,
                app_config => $app_config,
                params     => $params
            );
        }
        catch {
            chomp(my $err = $_);
            my $otc_prefix = $method =~ tr/_/./;
            if (my $message = $ERROR_MAP{$err}) {
                stats_inc($otc_prefix . '.error', {tags => ['error_code:' . $err]});
                return BOM::RPC::v3::Utility::create_error({
                        code              => $err,
                        message_to_client => localize($message)});
            } else {
                # This indicates a bug in the code.
                stats_inc($otc_prefix . '.error', {tags => ['error_code:unknown']});
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'OTCError',
                        message_to_client => localize('Sorry, an error occurred.')});
            }
        }
        };
}

=head2 otc_agent_register

Requests registration for an agent account.

Each client is able to have at most one agent account.

=cut

otc_rpc otc_agent_register => sub {
    die "PermissionDenied\n";
};

=head2 otc_agent_update

Update agent details - default comment, name etc.

=cut

otc_rpc otc_agent_update => sub {
    die "PermissionDenied\n";
};

=head2 otc_agent_info

Returns information about the given agent (by ID).

=cut

otc_rpc otc_agent_info => sub {
    my (%args)   = @_;
    my $client   = $args{client};
    my $agent_id = $args{params}->{agent};
    ($agent_id) = grep { $MOCK_DATA{agent}{$_}{loginid} eq $client->loginid } values $MOCK_DATA{agent}->%*
        unless $agent_id;

    # Copy the agent details so that we can inject the ID
    my $agent = {($MOCK_DATA{agent}{$agent_id} or die "NotFound\n")->%*};

    $agent->{id} = $agent_id;
    return $agent;
};

=head2 otc_offer_create

Attempts to create a new offer.

=cut

otc_rpc otc_offer_create => sub {
    die "NotRegistered\n";
};

=head2 otc_offer_info

Returns information about an offer.

=cut

otc_rpc otc_offer_info => sub {
    my (%args) = @_;
    my $offer_id = $args{params}->{id};
    my $offer = $MOCK_DATA{offer}{$offer_id} or die "NotFound\n";

    # Copy the offer details so that we can inject the ID
    my $agent = {$offer->%*};

    $offer->{id} = $offer_id;
    return $offer;
};

=head2 otc_method_list

Returns a list of all available payment methods.

=cut

otc_rpc otc_method_list => sub {
    return [{
            method       => 'bank',
            name         => 'hsbc',
            display_name => 'HSBC'
        },
        {
            method => 'bank',
            name   => 'maybank',
            name   => 'Maybank'
        },
        {
            method => 'bank',
            name   => 'cimb',
            name   => 'CIMB'
        },
        {
            method => 'online',
            name   => 'alipay',
            name   => 'AliPay'
        },
        {
            method    => 'online',
            name      => 'fps',
            full_name => 'FPS'
        },
        {
            method    => 'mobile',
            name      => 'grabpay',
            full_name => 'GrabPay'
        },
        {
            method    => 'mobile',
            name      => 'jompay',
            full_name => 'JOMPay'
        },
        {
            method => 'other',
            name   => 'other',
            name   => 'Other'
        },
    ];
};

=head2 otc_offer_list

Returns available offers.

=cut

otc_rpc otc_offer_list => sub {
    return [
        map {
            ;
            +{$MOCK_DATA{offer}{$_}->%*, id => $_}
            } sort {
            $a <=> $b
            } keys $MOCK_DATA{offer}->%*;
    ];
};

=head2 otc_offer_edit

Modifies details on an offer.

Typically used to cancel or confirm.

=cut

otc_rpc otc_offer_edit => sub {
    die "PermissionDenied\n";
};

=head2 otc_offer_remove

Removes an offer entirely.

=cut

otc_rpc otc_offer_remove => sub {
    die "PermissionDenied\n";
};

=head2 otc_order_create

Creates a new order for an offer.

=cut

otc_rpc otc_order_create => sub {
    die "PermissionDenied\n";
};

=head2 otc_order_list

Lists orders.

=cut

otc_rpc otc_order_list => sub {
    return [
        map {
            ;
            +{$MOCK_DATA{order}{$_}->%*, id => $_}
            } sort {
            $a <=> $b
            } keys $MOCK_DATA{order}->%*;
    ];
};

=head2 otc_order_confirm

Shortcut for updating order status to C<confirmed>.

=cut

otc_rpc otc_order_confirm => sub {
    die "PermissionDenied\n";
};

=head2 otc_order_cancel

Shortcut for updating order status to C<cancelled>.

=cut

otc_rpc otc_order_cancel => sub {
    die "PermissionDenied\n";
};

=head2 otc_order_chat

Exchange chat messages.

=cut

otc_rpc otc_order_chat => sub {
    die "PermissionDenied\n";
};

=head2 escrow_for_currency

Helper function to return an escrow account.

TAkes the following parameters:

=over 4

=item * C<$broker> - e.g. C<CR>

=item * C<$currency> - e.g. C<USD>

=back

Returns a L<BOM::User::Client> instance or C<undef> if not found.

=cut

sub escrow_for_currency {
    my ($broker, $currency) = @_;
    my $escrow_list = BOM::Config::Runtime->instance->app_config->otc->escrow->@*;
    while (my $loginid = shift @escrow_list) {
        my $acc = try {
            my $escrow_account = BOM::User::Client->new({login_id => $loginid})
                or return undef;

            return undef unless $escrow_account->broker eq $broker;
            return undef unless my $acc = $escrow_account->default_account;
            return undef unless $acc->currency eq $currency;

            return $escrow_account;
        }
        catch {
            return undef;
        };
        return $acc if $acc;
    }
    return undef;
}

1;

