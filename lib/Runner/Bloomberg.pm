package Runner::Bloomberg;

use Moose;

use lib ("/home/git/regentmarkets/bom/t/BOM/Product");
use Path::Tiny;
use List::Util qw(sum max);
use BOM::Config::Runtime;
use CSVParser::Bloomberg;
has suite => (
    is      => 'ro',
    isa     => 'Str',
    default => 'mini',
);

has 'files' => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [qw(1 2 3 4 5 6 7a 7b 8a 8b 9a 9b 10 11 12 13 14 15 16)] },
);

has report_file => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            all           => path('/tmp/ovra_result_file.csv'),
            analysis_base => path('/tmp/ovra_base_analysis_file.csv'),
            analysis_num  => path('/tmp/ovra_num_analysis_file.csv')};
    },
);

sub run_dataset {
    my $self = shift;

    my $file_loc = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/bloomberg';
    my @files    = @{$self->files};

    my $result_all;
    my @result_output;
    my $csv_header;

    foreach my $file (@files) {
        my $generator     = CSVParser::Bloomberg->new({output_format => 'Bloomberg'});
        my @lines         = path($file_loc . "/$file.csv")->lines;
        my @result_output = $generator->price_list([@lines], $self->suite);
        $csv_header = $result_output[0];
        my $content = $result_output[1] || '';
        $result_all .= $content;
    }

    my $output = $csv_header . $result_all;
    my $file   = $self->report_file->{all};
    $file->spew($output);

    my $csv               = Text::CSV::Slurp->load(file => $file);
    my @base_results      = grep { $_->{'base/numeraire'} eq 'base' } @$csv;
    my @numeraire_results = grep { $_->{'base/numeraire'} eq 'numeraire' } @$csv;

    my $base_breakdown;
    my $num_breakdown;

    foreach my $record (@base_results) {
        my $bettype = $record->{Type};
        push @{$base_breakdown->{$bettype}}, $record->{error_mid};
    }

    foreach my $record (@numeraire_results) {
        my $bettype = $record->{Type};
        push @{$num_breakdown->{$bettype}}, $record->{error_mid};
    }

    my $analysis_base = generate_and_save_analysis_report($self->report_file->{analysis_base}, $base_breakdown);
    my $analysis_num  = generate_and_save_analysis_report($self->report_file->{analysis_num},  $num_breakdown);

    return {
        BASE => $analysis_base,
        NUM  => $analysis_num,
    };
}

sub generate_and_save_analysis_report {
    my ($file, $analysis) = @_;

    $file->spew("BET_TYPE,AVG_MID,MAX_MID\n");
    my $analysis_report;

    foreach my $bettype (keys %$analysis) {
        my @mids   = @{$analysis->{$bettype}};
        my $record = scalar @mids;
        my $avg    = sum(@mids) / $record;
        my $max    = max(@mids);
        $analysis_report->{$bettype}->{avg} = $avg;
        $analysis_report->{$bettype}->{max} = $max;
        $file->append("$bettype,$avg,$max\n");
    }

    return $analysis_report;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
