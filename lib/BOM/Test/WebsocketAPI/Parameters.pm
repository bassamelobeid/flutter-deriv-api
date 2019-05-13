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
our @EXPORT_OK = qw( expand_params test_params );

use Finance::Underlying;
use Struct::Dumb qw( -named_constructors );
use Data::Dumper;

struct Client => [qw(
        loginid
        account_id
        country
        balance
        token
        email
        landing_company_name
        currency
        )];

struct TicksHistory  => [qw( times prices )];
struct ProposalArray => [qw( contract_types barriers )];
struct Contract      => [qw(
        buy_tx_id
        sell_tx_id
        contract_id
        is_sold
        contract_type
        underlying
        client
        amount
        balance_after
        )];

my $history_count = 10;
my $barrier_count = 2;
my $ticks_history;
my $proposal_array;
my $tx_id;
my $contract_id;

my @contract_type = qw(CALL PUT);
my @underlying    = Finance::Underlying->all_underlyings;

my @client = (
    Client(
        loginid              => 'CR90000000',
        account_id           => '201139',
        country              => 'id',
        balance              => '10000.00',
        token                => 'FakeToken',
        email                => 'binary@binary.com',
        landing_company_name => 'svg',
        currency             => 'USD',
    ),
);

my $now = time;
for my $ul (@underlying) {
    $ticks_history->{$ul->symbol} = TicksHistory(
        prices => [map { $ul->pipsized_value(10 + (100 * rand)) } (1 .. $history_count)],
        times => [map { $now - $_ } reverse(1 .. $history_count)],
    );

    $proposal_array->{$ul->symbol} = ProposalArray(
        contract_types => [@contract_type],
        barriers       => [map { $ul->pipsized_value(10 + (100 * rand)) } (1 .. $barrier_count)],
    );

}

my $parameters = {
    underlying     => \@underlying,
    currency       => [qw(USD AUD)],
    country        => [qw(aq id)],
    contract_type  => \@contract_type,
    ticks_history  => [$ticks_history],
    global         => [{req_id => 10000}],
    proposal_array => [$proposal_array],
    client         => \@client,
    # Will be filled dynamically when test_params is called
    contract => [],
};

=head2 test_params

Returns a hashref containing requested test parameters specified in C<@params>
If nothing is passed to C<@params> all available test params will be returned.

    # First client used for testing
    test_params(qw(client))->{client}[0]

=cut

sub test_params {
    my (@params) = @_;

    die 'Missing parameters to test_params' unless @params;

    my %test_params = $parameters->%{@params};

    if (exists $test_params{contract}) {
        # Dynamically generate contracts
        for my $ul (@underlying) {
            my %balances;
            for my $contract_type (@contract_type) {
                for my $client (@client) {
                    $balances{$client} //= $client->balance;
                    push $test_params{contract}->@*,
                        Contract(
                        buy_tx_id     => ++$tx_id,
                        sell_tx_id    => ++$tx_id,
                        contract_id   => ++$contract_id,
                        is_sold       => 0,
                        contract_type => $contract_type,
                        underlying    => $ul,
                        client        => $client,
                        balance_after => sprintf('%.2f', $balances{$client} -= 10),
                        amount        => '10.00',
                        );
                }
            }
        }
    }

    return \%test_params;
}

=head2 expand_params

Gets a list of param names and returns the expanded test parameters.

=cut

sub expand_params {
    my (@params) = @_;

    return map { params($_->%*) } permutations(test_params(@params, qw(global))->%*)->@*;
}

sub params { return BOM::Test::WebsocketAPI::Parameters::Params->new(@_) }

=head2 permutaitons

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
