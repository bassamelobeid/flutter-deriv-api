package BOM::Test::WebsocketAPI::Parameters;

no indirect;
use warnings;
use strict;

=head1 NAME

BOM::Test::WebsocketAPI::Parameters - Stores parameters to generate test data

=head1 SYNOPSIS

    use BOM::Test::WebsocketAPI::Parameters qw( expand_params );

    for (expand_params(qw(client contract)) {
        # Call code with all possible combination of clients and contracts
        $code->();
    }

=head1 DESCRIPTION


=cut

use Exporter;
our @ISA       = qw( Exporter );
our @EXPORT_OK = qw( expand_params test_params clients );

use Finance::Underlying;
use Struct::Dumb qw( -named_constructors );
use Date::Utility;

struct ParamLists => [qw(
        underlying
        ticks_history
        global
        proposal_array
        client
        contract
        )];

struct Client => [qw(
        loginid
        account_id
        country
        balance
        total_balance
        token
        email
        landing_company_name
        landing_company_fullname
        currency
        is_virtual
        )];

struct TicksHistory  => [qw( underlying times prices )];
struct ProposalArray => [qw(
        underlying
        client
        contract_types
        barriers
        basis
        duration
        duration_unit
        amount
        amount_str
        longcodes
        )];
struct Contract => [qw(
        buy_tx_id
        sell_tx_id
        contract_id
        is_sold
        contract_type
        underlying
        client
        amount
        amount_str
        balance_after
        barrier
        basis
        duration
        duration_unit
        shortcode
        longcode
        date_expiry
        start_time
        start_time_dt
        current_time
        payout
        payout_str
        status
        bid_price_str
        entry_tick
        )];

my $history_count = 10;
my $barrier_count = 2;
my $tx_id;
my $contract_id;

my @contract_type = qw(CALL PUT);
my @underlying    = Finance::Underlying->all_underlyings;

my @client = (
    Client(
        loginid                  => 'MLT90000000',
        account_id               => '200000',
        country                  => 'uk',
        balance                  => '10000.00',
        total_balance            => '30000.00',
        token                    => 'TestTokenMLT',
        email                    => 'binary@binary.com',
        landing_company_name     => 'mlt',
        landing_company_fullname => 'Binary (Europe) Ltd',
        currency                 => 'EUR',
        is_virtual               => 0,
    ),
    Client(
        loginid                  => 'CR90000000',
        account_id               => '200001',
        country                  => 'id',
        balance                  => '10000.00',
        total_balance            => '30000.00',
        token                    => 'TestTokenCR',
        email                    => 'binary@binary.com',
        landing_company_name     => 'svg',
        landing_company_fullname => 'Binary (SVG) Ltd.',
        currency                 => 'USD',
        is_virtual               => 0,
    ),
    Client(
        loginid                  => 'VRTC90000000',
        account_id               => '200002',
        country                  => 'id',
        balance                  => '10000.00',
        total_balance            => '30000.00',
        token                    => 'TestTokenVRTC',
        email                    => 'binary@binary.com',
        landing_company_name     => 'virtual',
        landing_company_fullname => 'Binary Ltd',
        currency                 => 'USD',
        is_virtual               => 1,
    ),
);

my @ticks_history;
my @proposal_array;
my @contract;

my $now            = time;
my $current_time   = $now;
my $date_expiry    = $now + (5 * 24 * 3600);
my $date_expiry_dt = Date::Utility->new($date_expiry);
my $start_time     = $now - 2;
my $start_time_dt  = Date::Utility->new($now - 2);
my $barrier        = 'S0P';
my $payout         = 20.43;

my %balances;
for my $ul (@underlying) {
    push @ticks_history,
        TicksHistory(
        underlying => $ul,
        prices     => [map { $ul->pipsized_value(10 + (100 * rand)) } (1 .. $history_count)],
        times => [map { $now - $_ } reverse(1 .. $history_count)],
        );

    my @barriers = map { $ul->pipsized_value(10 + (100 * rand)) } (1 .. $barrier_count);
    my $longcodes;

    for my $contract_type (@contract_type) {
        for my $barrier (@barriers) {
            $longcodes->{$contract_type}{$barrier} = sprintf(
                'Win payout if %s is strictly %s than %s at close on %s.',
                $ul->display_name, $contract_type eq 'CALL' ? 'higher' : 'lower',
                $barrier, $date_expiry_dt->date_yyyymmdd,
            );
        }
    }
    for my $client (@client) {
        push @proposal_array,
            ProposalArray(
            underlying     => $ul,
            basis          => 'stake',
            duration       => 5,
            duration_unit  => 'd',
            client         => $client,
            contract_types => [@contract_type],
            amount         => 10,
            amount_str     => '10.00',
            barriers       => \@barriers,
            longcodes      => $longcodes,
            );

        for my $contract_type (@contract_type) {
            $balances{$client} //= $client->balance;

            push @contract,
                Contract(
                buy_tx_id     => ++$tx_id,
                sell_tx_id    => ++$tx_id,
                contract_id   => ++$contract_id,
                is_sold       => 0,
                contract_type => $contract_type,
                underlying    => $ul,
                client        => $client,
                balance_after => sprintf('%.2f', $balances{$client} -= 10),
                amount_str    => '10.00',
                amount        => 10,
                basis         => 'stake',
                barrier       => $barrier,
                duration      => 5,
                duration_unit => 'd',
                payout        => $payout,
                payout_str    => '' . $payout,
                shortcode     => sprintf('%s_%s_%s_%s_%s_%s_0', $contract_type, $ul->symbol, $payout, $start_time, $date_expiry, $barrier,),
                longcode      => sprintf(
                    'Win payout if %s is strictly %s than entry spot at close on %s.',
                    $ul->display_name,
                    $contract_type eq 'CALL' ? 'higher' : 'lower',
                    $date_expiry_dt->date_yyyymmdd,
                ),
                date_expiry   => $date_expiry,
                start_time    => $start_time,
                start_time_dt => $start_time_dt,
                current_time  => $current_time,
                status        => 'open',
                bid_price_str => '9.36',
                entry_tick    => $contract_type eq 'CALL' ? $barriers[0] : $barriers[1],
                );
        }
    }
}

our $parameters = {
    underlying     => \@underlying,
    ticks_history  => \@ticks_history,
    global         => [{req_id => 10000}],
    proposal_array => \@proposal_array,
    client         => \@client,
    contract       => \@contract,
};
$parameters->{param_lists} = [ParamLists($parameters->%*)];

=head2 test_params

returns a hashref containing the test parameters used to generate test data.

=cut

sub test_params {
    return $parameters;
}

=head2 clients

Returns an arrayref containing the test clients.

=cut

sub clients {
    return \@client;
}

=head2 expand_params

Gets a list of param names and returns the expanded test parameters.

Template files accept their test params using the special variable C<$_>, each
template accepts a list of parameters to pass to the template generator code.

The special parameter C<global> is passed to every template and is a global
hashref shared between all templates (used mostly for sharing data, but can also
be used instead of creating module level variables, such as counters, etc.

Each given param has a corresponding list of available data in L<$parameters>
which is then selected and a list of all possible test values is generated using
the C<permutations> functions.

Each request template is then called with the parameters in that list to
generate all possible requests (either API or RPC requests).

For RPC responses and published values, we don't generate them beforehand,
instead we wait until an RPC request is made then find out which sets of params
were used to generate that RPC request and pass it to publish and RPC response
data.

See the L<Template/DSL.pm> for more info.

=cut

sub expand_params {
    my (@params) = @_;

    return map { params($_->%*) } permutations($parameters->%{(@params, qw(global param_lists))})->@*;
}

sub params { return BOM::Test::WebsocketAPI::Parameters::Params->new(@_) }

=head2 permutations

Creates a list of permutations of options to pass to code

=cut

sub permutations {
    my (%options) = @_;

    if (!%options) {    # permutations()
        return [];
    }

    my ($key) = sort keys %options;

    if (keys %options == 1) {    # permutations(a => [1,2])
        return [
            map {
                { $key => $_ }
            } $options{$key}->@*
        ];
    }

    my $values = delete $options{$key};

    if ($values->@* == 1) {      # permutations(a => [1], b => [qw(x)])
        return [
            map {
                { $key => $values->[0], $_->%* }
            } permutations(%options)->@*
        ];
    }

    # permutations(a => [1,2], b => [qw(x y)])
    my $result;
    for my $permutations (permutations($key => $values)->@*) {
        push $result->@*, map {
            {
                ($permutations->%*, $_->%*)
            }
        } permutations(%options)->@*;
    }
    return $result;
}

{

    package BOM::Test::WebsocketAPI::Parameters::Params;    ## no critic (Modules::ProhibitMultiplePackages)

    sub new { return bless {@_[1 .. $#_]}, $_[0] }

    no strict 'refs';

    for my $p (keys $parameters->%*) {
        *$p = sub { $_[0]->{$p} };
    }

    1;
}

1;
