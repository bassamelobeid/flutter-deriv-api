package CSVParser::NTO;

=head1 NAME

NTOCSVParser

=head1 DESCRIPTION

Parses our Next Top Option CSV file, converting the raw data into
information in our various internal format.

=cut

use Moose;
use Text::CSV::Slurp;

=head1 ATTRIBUTES

=head2 nto_csv

The location of the Next Top Option CSV file.

=cut

has nto_csv => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has records_to_price => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

=head2 records

An ArrayRef of HashRefs, each corresponding to one line
from the CSV file, and containing all info necessary for
us to run our various tests.

=cut

has records => (
    is         => 'ro',
    isa        => 'ArrayRef',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_records {
    my $self = shift;

    my $csv = Text::CSV::Slurp->load(file => $self->nto_csv);
    my @records;

    my $previous_underlying_symbol = '';
    my $previous_underlying;
    my $previous_surface;

    foreach my $line (@$csv) {
        next if not $line->{asset};
        my $current_underlying_symbol = $line->{asset};
        my %record                    = (
            underlying        => $current_underlying_symbol,
            date_start        => Date::Utility->new($line->{start_date}),
            spot              => $line->{spot},
            currency          => 'USD',
            payout            => $line->{payout},
            bet_type          => $line->{bet_type},
            nto_return        => $line->{nto_return},
            bet_num           => $line->{no},
            date_expiry       => Date::Utility->new($line->{end_date}),
            nto_client_profit => $line->{nto_client_profit},
            nto_win           => $line->{nto_client_profit} > 0 ? 1 : 0,
            nto_buy_price     => $line->{nto_buy_price},
        );
        push @records, \%record;
    }
    return \@records;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
