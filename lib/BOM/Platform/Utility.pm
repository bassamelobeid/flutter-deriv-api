package BOM::Platform::Utility;

use strict;
use warnings;

use Clone::PP qw(clone);
use BOM::Config::Runtime;
use List::Util qw(any);
use Brands::Countries;

=head1 NAME

BOM::Platform::Utility

=head1 DESCRIPTION

A collection of helper methods.

=cut

=head2 hash_to_array

Extract values from a hashref and returns as an arrayref.

It takes a hashref:

=over 4

=item * C<hash> an input hashref 

Example:
    $input: {
        a => ['1', '2', '3'],
        b => {
            c => ['4', '5', '6'],
            d => ['7', '8', '9'],
        }
    }
    # see test

=back

Returns an arrayref.

Example:
    $output: ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

=cut

sub hash_to_array {
    my ($hash) = @_;
    return _hash_to_array_helper([], [clone($hash)]);
}

=head2 _hash_to_array_helper

Recursively calls itself and extract values from a hashref $stack.

It takes:

=over 4

=item * C<array> an arrayref that holds the output values 

=item * C<stack> an arrayref of a copy of input hash

=back

Returns an arrayref that holds the values of a hash.

=cut

sub _hash_to_array_helper {
    my ($array, $stack) = @_;

    return $array unless $stack->@*;

    my $temp_stack = [];
    foreach my $value ($stack->@*) {
        next unless defined $value;

        my $refs = $value;
        $refs = [$value] unless ref $value eq 'ARRAY';

        for ($refs->@*) {
            push $temp_stack->@*, values $_->%* if ref $_ eq 'HASH';
            push $temp_stack->@*, $_->@*        if ref $_ eq 'ARRAY';
            push $array->@*,      $_ unless ref $_;
        }
    }
    return _hash_to_array_helper($array, $temp_stack);
}

=head2 extract_valid_params

Extract valid params by testing againest regex

=over 4

=item * C<params> fields to be filtered
=item * C<args> values of C<params>
=item * C<regex_validation_keys> hash contains key and value regex as key/value pair.

=back

Returns valid params

=cut

sub extract_valid_params {
    my ($params, $args, $regex_validation_keys) = @_;

    my %filtered_params;
    my @remaining_params = $params->@*;

    foreach my $key_regex (keys $regex_validation_keys->%*) {
        my $value_regex = $regex_validation_keys->{$key_regex};

        %filtered_params = (
            %filtered_params, map { $_ => $args->{$_} }
                grep { defined $args->{$_} && $_ =~ $key_regex && $args->{$_} =~ $value_regex } @remaining_params
        );
        @remaining_params = grep { $_ !~ $key_regex } @remaining_params;
    }

    %filtered_params = (%filtered_params, map { $_ => $args->{$_} } @remaining_params);
    return \%filtered_params;
}

=head2 is_idv_disabled

Checks if IDV has been dynamically disabled.

=over 4

=item C<args>: hash containing country and provider

=back

Returns bool

=cut

sub is_idv_disabled {
    my %args = @_;
    # Is IDV disabled
    return 1 if BOM::Config::Runtime->instance->app_config->system->suspend->idv;
    # Is IDV country disabled
    my $disabled_idv_countries = BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries;
    if (defined $args{country}) {
        return 1 if any { $args{country} eq $_ } @$disabled_idv_countries;
    }
    # Is IDV provider disabled
    my $disabled_idv_providers = BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers;
    if (defined $args{provider}) {
        return 1 if any { $args{provider} eq $_ } @$disabled_idv_providers;
    }
    return 0;
}

=head2 has_idv

Checks if IDV is enabled and supported for the given country + provider

=over 4

=item C<args>: hash containing country and provider

=back

Returns bool

=cut

sub has_idv {
    my %args            = @_;
    my $country_configs = Brands::Countries->new();
    return 0 unless $country_configs->is_idv_supported($args{country} // '');

    return 0 if is_idv_disabled(%args);

    return 1;
}

1;
