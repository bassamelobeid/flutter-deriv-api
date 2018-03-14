package BOM::Product::QuantsConfig;

use Moose;

use Try::Tiny;
use JSON::MaybeXS;

use List::Util qw(any first);
use BOM::Platform::Chronicle;
use BOM::Platform::Runtime;

use constant {NAMESPACE => 'quants_config'};

my $json = JSON::MaybeXS->new->allow_blessed;

has _supported_config_name => (
    is      => 'ro',
    default => sub {
        {
            limits => {
                potential_loss => 1,
                realized_loss  => 1,
            }};
    },
);

=head2 get_config

Get config for $config_name.

If $client is provided, it will fetch config in this manner:

1. return if client config is found. Else,
2. return if landing company specific to the client's config is found. Else,
3. return default config

=cut

sub get_config {
    my ($self, $args) = @_;

    if (my $missing = first { !$args->{$_} } qw(config_type barrier_category expiry_type config_name underlying)) {
        die "Missing required parameter[$missing]";
    }

    my $supported   = $self->_supported_config_name;
    my $config_type = $args->{config_type};
    die "Unsupported config_type[$args->{config_type}], allowed[" . (join '|', keys %$supported) . "]"
        unless $supported->{$config_type};
    die "Unsupported barrier_category[$args->{barrier_category}, allowed[atm|non_atm]"
        unless any { $_ eq $args->{barrier_category} } qw(atm non_atm);
    die "Unsupported expiry_type[$args->{expiry_type}], allowed[tick|intraday|multiday]"
        unless any { $_ eq $args->{expiry_type} } qw(tick intraday multiday);
    die "Unsupported config_name[$args->{config_name}], allowed[" . (join '|', keys %{$supported->{$config_type}}) . "]"
        unless $supported->{$config_type}->{$args->{config_name}};

    my $config = $self->_get($args);
    my $data   = $config->{$args->{config_type}}{$args->{barrier_category}}{$args->{expiry_type}}{$args->{config_name}};

    my $symbol_level = $json->decode($data->per_underlying_symbol);
    if (my $limit = $symbol_level->{$args->{underlying}->symbol}) {
        return $limit;
    }

    my $submarket_level = $json->decode($data->per_submarket);
    if (my $limit = $submarket_level->{$args->{underlying}->market->name}) {
        return $limit;
    }

    my $market_level = $json->decode($data->per_market);
    if (my $limit = $market_level->{$args->{underlying}->submarket->name}) {
        return $limit;
    }

    # if it ever reaches here, returns an limit of zero since we don't know what it is.
    return 0;
}

sub _get {
    my ($self, $args) = @_;

    my $runtime = BOM::Platform::Runtime->instance;

    if (my $client = $args->{client}) {
        my $reader = BOM::Platform::Chronicle::get_chronicle_reader();
        return $runtime->quants_config($client->loginid)                if $reader->get(NAMESPACE, $client->loginid);
        return $runtime->quants_config($client->landing_company->short) if $reader->get(NAMESPACE, $client->landing_company->short);
    }

    return $runtime->quants_config('default');
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
