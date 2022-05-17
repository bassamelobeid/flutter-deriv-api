package Commission::Monitor;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use YAML::XS qw(LoadFile);
use Log::Any qw($log);
use Database::Async;
use Database::Async::Engine::PostgreSQL;
use BOM::Platform::Email qw(send_email);
use Brands;
use Net::Async::Redis;

our $VERSION = '0.1';

=head1 NAME

Commission::Monitor - monitors commission definition for instrument list for CFD platforms

=cut

=head2 new

Creates a new instance of Commission::Monitor

=over 4

=item * cfd_provider - dxtrade or mt5

=item * db_server - defaults to commission01

=item * redis_config - config file for redis.

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        cfd_provider => $args{cfd_provider} || 'dxtrade',
        db_service   => $args{db_service}   || 'commission01',
        redis_config => $args{redis_config} || '/etc/rmg/redis-cfds.yml',
    };

    return bless $self, $class;
}

=head2 start

main loop that runs the data comparison

=cut

async sub start {
    my $self = shift;

    my $data            = await $self->{redis}->hgetall('DERIVX_CONFIG::INSTRUMENT_LIST');
    my %trading_symbols = $data->@*;

    my $db_symbols =
        await $self->{_dbic}->query(q{select * from affiliate.commission where provider=$1}, $self->{cfd_provider})->row_hashrefs->as_arrayref;
    my %db_symbols_map = map { $_->{mapped_symbol} => 1 } $db_symbols->@*;

    my %missing_commission;
    foreach my $ts (keys %trading_symbols) {
        $missing_commission{$ts}++ unless ($db_symbols_map{$ts});
    }

    if (%missing_commission) {
        my $symbol_str = join "\n", keys %missing_commission;
        my $message    = <<MM;
Commission is not defined on $self->{cfd_provider} for the following symbols:
$symbol_str
MM

        my $brands = Brands->new;
        send_email({
            from    => $brands->emails('system'),
            to      => $brands->emails('quants'),
            subject => "Missing commission for $self->{cfd_provider}",
            message => [$message],
        });
    }
}

=head2 _add_to_loop

Init commission database and devexperts client

=cut

sub _add_to_loop {
    my $self = shift;

    my %parameters = (
        pool => {
            max => 1,
        },
        engine => {service => $self->{db_service}},
        type   => 'postgresql',
    );

    $self->{_dbic} = Database::Async->new(%parameters);

    $self->add_child($self->{_dbic});

    my $config = LoadFile($self->{redis_config});

    $self->{redis} = Net::Async::Redis->new(
        uri  => "redis://$config->{write}{host}:$config->{write}{port}",
        auth => $config->{write}{password},
    );

    $self->add_child($self->{redis});

    return;

}

1;
