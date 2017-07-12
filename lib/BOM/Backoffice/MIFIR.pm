package BOM::Backoffice::MIFIR;
use 5.014;
use warnings;
use strict;

use Text::Iconv;
use Date::Utility;
use Data::Dumper;
use YAML qw/LoadFile/;
use utf8;

my $converter = Text::Iconv->new("UTF-8", "ASCII//TRANSLIT//IGNORE");
our $config = LoadFile('mifir.yml');

sub process_name {
    my ($str) = @_;
    $str = lc($str);
    $str =~ s/$_\s+//g for (@{$config->{titles}}, @{$config->{prefixes}});
    $str = $converter->convert($str);
    $str =~ s/[^a-z]//g;
    if (length($str) < 5) {
        $str .= '#' x (5 - length($str));
    } else {
        $str = substr($str, 0, 5);
    }
    return $str;
}

sub generate {
    my $args = shift;
    my $cc   = $args->{cc};
    my $date = Date::Utility->new($args->{date})->date_yyyymmdd;
    $date =~ s/\-//g;
    my $first_name = process_name($args->{first_name});
    my $last_name  = process_name($args->{last_name});
    return uc($cc . $date . $first_name . $last_name);
}

1;
