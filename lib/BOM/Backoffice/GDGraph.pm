package BOM::Backoffice::GDGraph;
use strict;
use warnings;
use 5.010;

use utf8;
use File::Temp;
use GD::Graph::lines;
use Carp;
use File::Basename qw(fileparse);

our $VERSION = '1.0';

=head1 NAME

BOM::Utility::Utils

=head1 VERSION

1.0

=head1 SYNOPSYS

    use BOM::Utility::Utils

    my $encoded_text = BOM::Utility::Utils::encode_text("Hello world!");

=head1 DESCRIPTION

This module provides general purpose utility subroutines. It soes not export
anything by default. Use the full namespace to call any subroutines in this
module.

=head1 CAVEAT

Its a problem to maintain a top-level utility module. Many things can go wrong.
Firstly we can keep on adding "general purpose" subroutines in here, and the
number of such subroutines can increase greatly. I propose that we keep
the number of subs in this module to not more than I<seven>.

If you notice that two or more subroutines are similar, in that they perform a
task related to a specific domain, its best to move them out into their own
BOM::Utility::{Class} module.

Subroutines in here should only depend on CPAN, and not on any application
specific modules.

=head1 SUBROUTINES

=head2 generate_line_graph

Generates a graph and outputs it to a file. The filename is returned.

    my $filename = BOM::Utility::generate_line_graph({
            title  => "Plot comparison for $term day smile",
            x_axis => \@x_axis,
            charts => {
                first => {
                    label_name => 'original_smile',
                    data       => \@implied_smile
                },
                second => {
                    label_name => 'original_calibrated_smile',
                    data       => \@calibrated_smile
                },
            },
            x_label => 'smile_points',
            y_label => 'Volatility',
        });
=cut

sub generate_line_graph {
    my ($args) = @_;

    my $gif_dir = $args->{directory} || '/home/website/www/temp';
    mkdir $gif_dir unless -e $gif_dir;

    my $temp = File::Temp->new(
        DIR    => $gif_dir,
        SUFFIX => '.png',
        UNLINK => 0,
    );

    my $file = $temp->filename;
    chmod 0777, $file;
    my @data_label;
    my @chart_data = ($args->{x_axis});

    foreach my $key (keys %{$args->{charts}}) {
        push @data_label, $args->{charts}->{$key}->{label_name};
        push @chart_data, $args->{charts}->{$key}->{data};
    }

    my $data = GD::Graph::Data->new(\@chart_data);
    my $graph = GD::Graph::lines->new(600, 400);
    $graph->set_legend(@data_label);
    $graph->set(
        x_label => $args->{x_label} || 'x_label',
        y_label => $args->{y_label} || 'y_label',
        title   => $args->{title},
        dclrs   => [qw(dgreen dpink lblue)],
        y_max_value => $args->{y_max_value},
    ) or croak $graph->error;

    my $gp = $graph->plot($data) or croak $graph->error;
    open my $IMG, '>', $file or croak $!;
    binmode $IMG;
    print $IMG $gp->png;
    close $IMG;

    my ($filename) = fileparse($file);

    return $filename;
}

1;

