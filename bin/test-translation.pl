#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Try::Tiny;
use Test::MockModule;
use BOM::Platform::Context::I18N;
use Term::ANSIColor qw/color/;
use Getopt::Long;

my $dir = '/home/git/binary-com/binary-static/config/locales';
my $opt_help;

sub usage {
    return <<"USAGE";
test-translation.pl [--directory=DIR] [--help] PO_FILE_OR_LANGUAGE ...

OPTIONS

  --directory   specify the directory where PO files are to be found
                default: $dir
  --help        print this help and exit

DESCRIPTION

This script reads all message ids from the specified PO files and tries to
translate them into the destination language. PO files can be specified either
as file name (extension .po) or by providing the language. In the latter case
the PO file is found in the directory given by the --directory option.

TYPES OF ERRORS FOUND

* unknown %func() calls
  Translations can contain function calls in the form of %func(parameters).
  These functions must be defined in our code. Sometimes translators try to
  translate the function name which then calls an undefined function.

* incorrect number of %plural() parameters
  Different languages have different numbers of plural forms. Some, like Malay,
  don't have any plural forms. Some, like English or French, have just 2 forms,
  singular and one plural. Others like Arabic or Russian have more forms.
  Whenever a translator uses the %plural() function, he must specify the correct
  number of plural forms as parameters.

* incorrect usage of %d in %plural() parameters
  In some languages, like English or German, singular is applicable only to the
  quantity of 1. That means the German translator could come up for instance
  with the following valid %plural call:

    %plural(%5,ein Stein,%d Steine)

  In other languages, like French or Russian, this would be an error. French
  uses singular also for 0 quantities. So, if the French translator calls:

    %plural(%5,une porte,%d portes)

  and in the actual call the quantity of 0 is passed the output is still
  "une porte". In Russian the problem is even more critical because singular
  is used for instance also for the quantity of 121.

  Thus, this test checks if a) the target language is similar to English in
  having only 2 plural forms, singular and one plural, and in applying
  singular only to the quantity of 1. If both of these conditions are met
  %plural calls like the above are allowed. Otherwise, if at least one of
  the parameters passed to %plural contains a %d, all of the parameters must
  contain the %d as well.

  That means the following 2 %plural calls are allowed in Russian:

    %plural(%3,%d книга,%d книги,%d книг)
    %3 %plural(%3,книга,книги,книг)

  while this is forbidden:

    %plural(%3,одна книга,%d книги,%d книг)
USAGE
}

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

GetOptions 'directory=s' => \$dir,
           'help'        => \$opt_help,
    or die usage;

if ($opt_help) {
    print usage;
    exit 0;
}

select STDERR;
$| = 1;
select STDOUT;

my @lang = sort do {
    if (opendir my $dh, $dir) {
        grep {s/^(\w+)\.po$/$1/} readdir $dh
    } else {
        ();
    }
};

@lang = @ARGV if @ARGV;

{
    my $status = 0;
    sub elog {
        my $severity = shift;
        my $lg = shift;
        my $ln = shift;
        my $prefix = color('bright_yellow bold') . "WARNING" . color('reset');
        $status = $severity if $severity > $status;
        $prefix = color('bright_red bold') . "ERROR" . color('reset') if $severity;

        print STDERR join '', "$prefix (lang=$lg, line=$ln): ", @_, "\n";
    }
    sub exit_status {
        return $status;
    }
}

sub cstring {
    my %map = (
               'a' => "\007",
               'b' => "\010",
               't' => "\011",
               'n' => "\012",
               'v' => "\013",
               'f' => "\014",
               'r' => "\015",
              );
    return $_[0] =~ s/
                         \\
                         (?:
                             ([0-7]{1,3})
                         |
                             x([0-9a-fA-F]{1,2})
                         |
                             ([\\'"?abfvntr])
                         )
                     /$1 ? chr(oct($1)) : $2 ? chr(hex($2)) : ($map{$3} || $3)/regx;
}

sub bstring {
    my @params;
    return $_[0] =~ s!
                         (?>                       # matches %func(%N,parameters...)
                             %
                             (?<func>\w+)
                             \(
                             %
                             (?<p0>[0-9]+)
                             (?<prest>[^\)]*)
                             \)
                         )
                     |
                         (?>                       # matches %func(parameters)
                             %
                             (?<simplefunc>\w+)
                             \(
                             (?<simpleparm>[^\)]*)
                             \)
                         )
                     |                             # matches %N
                         %
                         (?<simple>[0-9]+)
                     |                             # [, ] and ~ should be escaped as ~[, ~] and ~~
                         (?<esc>[\[\]~])
                     !
                         if ($+{esc}) {
                             "~$+{esc}";
                         } elsif ($+{simplefunc}) {
                             "[$+{simplefunc},$+{simpleparm}]";
                         } else {
                             my $pos = ($+{func} ? $+{p0} : $+{simple}) - 1;
                             $params[$pos] = $+{func} && $+{func} eq 'plural' ? 'plural' : ($params[$pos] // 'text');
                             $+{func} ? "[$+{func},_$+{p0}$+{prest}]" : "[_$+{simple}]";
                         }
                     !regx,
           \@params;
}

{
    my @stack;
    sub nextline {
        return pop @stack if @stack;
        return scalar readline $_[0];
    }

    sub unread {
        push @stack, @_;
    }
}

sub get_trans {
    my $f = shift;

    while (defined (my $l = nextline $f)) {
        if ($l =~ /^\s*msgstr\s*"(.*)"/) {
            my $line = $1;
            while (defined ($l = nextline $f)) {
                if ($l =~ /^\s*"(.*)"/) {
                    $line .= $1;
                } else {
                    unread $l;
                    return cstring($line);
                }
            }
            return cstring($line);
        }
    }
}

sub get_po {
    my $lang        = shift;
    my $header_only = shift;

    unless ($lang =~ /\.po$/) {
        $lang = $dir . '/'. $lang . '.po';
    }

    my %header;
    my @ids;
    my $first = 1;
    my $ln;

    open my $f, '<:utf8', $lang or die "Cannot open $lang: $!\n";
 READ:
    while (defined (my $l = nextline $f)) {
        if ($l =~ /^\s*msgid\s*"(.*)"/) {
            my $line = $1;
            $ln = $.;
            while (defined ($l = nextline $f)) {
                if ($l =~ /^\s*"(.*)"/) {
                    $line .= $1;
                } else {
                    unread $l;
                    if ($first) {
                        undef $first;
                        %header = map {split /\s*:\s*/, lc($_), 2} split /\n/, get_trans($f);
                        last READ if $header_only;
                    } elsif (length $line) {
                        push @ids, [bstring(cstring($line)), get_trans($f), $ln];
                    }
                    last;
                }
            }
        }
    }

    return {
            header => \%header,
            ids    => \@ids,
            lang   => $header{language},
            file   => $lang,
           };
}

my $orig_configs_for = \&BOM::Platform::Context::I18N::configs_for;
my $mock = Test::MockModule->new('BOM::Platform::Context::I18N', no_auto => 1);
$mock->mock(configs_for => sub {
    my $config = $orig_configs_for->(@_);

    delete @{$config}{grep {!/^_/} keys %$config};
    for my $lang (@lang) {
        my $po = get_po $lang, 'header_only';
        $config->{uc $po->{lang}} = [Gettext => $po->{file}];
    }

    #use Data::Dumper; print Data::Dumper->new([$config])->Useqq(1)->Sortkeys(1)->Dump;

    return $config;
});

for my $lang (@lang) {
    my $po = get_po $lang;

    my $lg = $po->{header}->{language};
    my $hnd = BOM::Platform::Context::I18N::handle_for($lg);

    $hnd->plural(1, 'test');
    my $plural_sub = $hnd->{_plural};

    my $nplurals = 2;            # default
    $nplurals = $1 if $po->{header}->{'plural-forms'} =~ /\bnplurals=(\d+);/;
    my @plural;

    for (my ($i, $j) = (0, $nplurals); $i<10000 && $j>0; $i++) {
        my $pos = $plural_sub->($i);
        unless (defined $plural[$pos]) {
            $plural[$pos] = $i;
            $j--;
        }
    }

    # $lang_plural_is_like_english==1 means the language has exactly 2 plural forms
    # and singular is applied only to the quantity of 1. That means something like
    # %plural(%d,ein Stern,%d Sterne) is allowed. In French for instance, singular is
    # also applied to the quantity of 0. In that case the singular form should also
    # contain a %d sequence.
    my $lang_plural_is_like_english = ($nplurals == 2);
    if ($lang_plural_is_like_english) {
        for (my $i = 0; $i <= 100_000; $i++) {
            next if $i == 1;
            if ($plural_sub->($i) == 0) {
                $lang_plural_is_like_english = 0;
                last;
            }
        }
    }

    my $ln;

    $plural_sub = $hnd->can('plural');
    my $mock = Test::MockModule->new(ref($hnd), no_auto => 1);
    $mock->mock(plural => sub {
                    # The plural call should provide exactly the number of forms required by the language
                    elog(1, $lg, $ln, "\%plural() requires $nplurals parameters for this language (provided: @{[@_ - 2]})")
                        unless @_ == $nplurals+2;

                    # %plural() can be used like
                    #
                    #     %plural(%3,word,words)
                    #
                    # or like
                    #
                    #     %plural(%3,%d word,%d words)
                    #
                    # In the first case we are only looking for the correct plural form
                    # providing the actual quantity elsewhere.
                    #
                    # The code below checks that either all parameters of the current call contain %d
                    # or none of them. That means something like %plural(%15,one word,%d words) is an
                    # error as singular is in many languages also applied to other quantities than 1.


                    my $found_percent_d = 0;
                    my @no_percent_d;
                    for (my $i = 2; $i < @_; $i++) {
                        if ($_[$i] =~ /%d/) {
                            $found_percent_d++;
                        } else {
                            # $i==2 means it's the singular parameter. This one is allowed to not contain
                            # %d if the language is like English
                            push @no_percent_d, $i - 1 unless ($i == 2 and $lang_plural_is_like_english);
                        }
                    }
                    if ($found_percent_d) {
                        if (@no_percent_d > 1) {
                            my $s = join(', ', @no_percent_d[0 .. $#no_percent_d - 1]) . ' and ' . $no_percent_d[-1];
                            elog(1, $lg, $ln, "\%plural() parameters $s miss %d");
                        } elsif (@no_percent_d == 1) {
                            elog(1, $lg, $ln, "\%plural() parameter $no_percent_d[0] misses %d");
                        }
                    }

                    goto $plural_sub;
                });

    for my $test (@{$po->{ids}}) {
        #use Data::Dumper; print Data::Dumper->new([$test])->Useqq(1)->Sortkeys(1)->Dump;
        $ln = $test->[3];
        my $i = 0;
        my $j = 0;
        my @param = map {
            $j++;
            elog(0, $lg, $ln, "unused parameter \%$j") unless defined $_;
            defined $_ && $_ eq 'text' ? 'text' . $i++ : 1;
        } @{$test->[1]};
        try {
            local $SIG{__WARN__} = sub { die $_[0] };
            $hnd->maketext($test->[0], @param);
        }
        catch {
            if (/Can't locate object method "([^"]+)" via package/) {
                elog(1, $lg, $ln, "Unknown directive \%$1()");
            } else {
                elog(1, $lg, $ln, "Unexpected error:\n$_");
            }
        };
    }
}

exit exit_status;
