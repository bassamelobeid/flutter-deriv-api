package BOM::Backoffice::MIFIR;
use 5.014;
use warnings;
use strict;

use Text::Iconv;
use Date::Utility;
use Data::Dumper;
use YAML qw/LoadFile/;
use utf8;

=head1 NAME

BOM::Backoffice::MIFIR - provides CONCAT code generation out of client data according to MIFIR rules

=head1 SYNOPSIS

    use BOM::Backoffice::MIFIR;

    print BOM::Backoffice::MIFIR::concat({
        date => '1960-01-01',
        first_name => 'Jack',
        last_name  => 'Daniels',
    });

=cut

my $converter = Text::Iconv->new("UTF-8", "ASCII//TRANSLIT//IGNORE");
our $config = LoadFile('/home/git/regentmarkets/bom-backoffice/config/mifir.yml');
our $romanization = LoadFile('/home/git/regentmarkets/bom-backoffice/config/romanization.yml');

sub concat {
    my $args = shift;
    my $cc   = $args->{cc};
    my $date = Date::Utility->new($args->{date})->date_yyyymmdd;
    $date =~ s/\-//g;
    my $first_name = process_name($args->{first_name});
    my $last_name  = process_name($args->{last_name});
    return uc($cc . $date . $first_name . $last_name);
}

sub _process_name {
    my ($str) = @_;
    $str = lc($str);
    $str =~ s/$_/$romanization->{$_}/g for keys %$romanization;
    $str =~ s/$_\s+//g for (@{$config->{titles}}, @{$config->{prefixes}});
    $str =~ s/’//g;              # our iconv does not handle this correctly, it returns empty string is we have it
    $str = $converter->convert($str);
    $str =~ s/[^a-z]//g;
    if (length($str) < 5) {
        $str .= '#' x (5 - length($str));
    } else {
        $str = substr($str, 0, 5);
    }
    return $str;
}
1;
