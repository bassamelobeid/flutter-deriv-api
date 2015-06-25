#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Try::Tiny;
use Test::MockModule;
use BOM::Platform::Context::I18N;
use Term::ANSIColor qw/color/;

select STDERR;
$| = 1;
select STDOUT;

binmode STDOUT, ':utf8';

my $dir = '/home/git/binary-com/binary-static/config/locales';
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
                         (?>
                             %(\w+)\(%([0-9]+)([^\)]*)\)
                         )
                     |
                         %([0-9]+)
                     |
                         ([\[\]~])
                     !
                         if ($5) {
                             "~$5";
                         } else {
                             my $pos = ($1 ? $2 : $4) - 1;
                             $params[$pos] = $1 && $1 eq 'plural' ? 'plural' : ($params[$pos] // 'text');
                             $1 ? "[$1,_$2$3]" : "[_$4]";
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
    my $lang = shift;

    unless ($lang =~ /\.po$/) {
        $lang = $dir . '/'. $lang . '.po';
    }

    my %header;
    my @ids;
    my $first = 1;
    my $ln;

    open my $f, '<:utf8', $lang or die "Cannot open $lang: $!\n";
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
           };
}

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

    my $ln;

    $plural_sub = $hnd->can('plural');
    my $mock = Test::MockModule->new(ref($hnd), no_auto => 1);
    $mock->mock(plural => sub {
                    elog(1, $lg, $ln, "insufficient number of parameters in \%plural()")
                        unless @_ == $nplurals+2;
                    for (my $i = 2; $i < @_; $i++) {
                        unless ($_[$i] =~ /%d/) {
                            if ($_[$i] =~ /\d/) {
                                elog(1, $lg, $ln, "\%plural() parameter " . ($i-1) . " misses %d")
                            } else {
                                elog(0, $lg, $ln, "\%plural() parameter " . ($i-1) . " misses %d")
                            }
                        }
                    }
                    goto $plural_sub;
                });

    for my $test (@{$po->{ids}}) {
        # use Data::Dumper; print Data::Dumper->new([$test])->Useqq(1)->Sortkeys(1)->Dump;
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
