package BOM::Rules::RuleRepository::Onfido;

=head1 NAME

BOM::Rules::RuleRepositry::Onfido

=head1 DESCRIPTION

Contains rules related to Onfido check ups

=cut

use strict;
use warnings;
use utf8;

use List::Util qw(any);
use JSON::MaybeUTF8 qw(:v1);
use LandingCompany::Registry;
use Text::Unidecode;

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry qw(rule);

rule 'onfido.name_check_comparison' => {
    description => "Checks if the context client first and last names match with the last Onfido report data",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'Client is missing'                 unless $context->client;
        die 'Onfido report is missing'          unless my $report = $args->{report};
        die 'Onfido report api_name is invalid' unless ($report->{api_name} // '') eq 'document';

        my $fields = [qw/first_name last_name/];

        my $properties = eval { decode_json_utf8($report->{properties} // '{}') };
        my $src        = join ' ', map { $context->client->$_ // '' } $fields->@*;
        my $cmp        = join ' ', map { $properties->{$_}    // '' } $fields->@*;

        die +{code => 'NameMismatch'} unless word_by_word_comparison($src, $cmp);
        return undef;
    },
};

=head2 word_by_word_comparison

Given strings C<$src> and C<$cmp>, this sub determines whether each word of C<$src>
is in C<$cmp> (word by word comparison).

It takes the following arguments:

=over 4

=item * C<$src> - the source of words.

=item * C<$cmp> - the words to compare to.

=back

Returns a C<1> if there is a match, C<0> otherwise.

=cut

sub word_by_word_comparison {
    my ($src, $cmp) = @_;
    my @source     = split ' ', lc unidecode($src) || return 0;
    my @repository = split ' ', lc unidecode($cmp) || return 0;

    for my $source (@source) {
        return 0 unless any { $source eq $_ } @repository;
    }

    return 1;
}

1;
