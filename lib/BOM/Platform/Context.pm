package BOM::Platform::Context;

=head1 NAME

BOM::Platform::Context

=head1 DESCRIPTION

A plain old perl module, containing all functions for current execution context and all variables in the current context.

=cut

use strict;
use warnings;

use feature 'state';
use Template;
use Template::AutoFilter;
use base qw( Exporter );

our @EXPORT_OK = qw(request localize template);

use Time::Duration::Concise::Localize;
use BOM::Platform::Context::Request;
use Format::Util::Numbers;
use BOM::Platform::Context::I18N;

state $current_request;
state $template_config = {};

=head2 request

The object representing the current request.

Current request is set by passing in a new I<BOM::Platform::Context::Request> object.

returns,
    An instance of BOM::Platform::Context::Request. current request if its set or default values if its not set.

=cut

sub request {
    my $new_request = shift;
    state $default_request = BOM::Platform::Context::Request->new();
    $current_request = _configure_for_request($new_request) if ($new_request);
    return $current_request // $default_request;
}

=head2 template

Correct instance of template_toolkit object for current request.

usage,
    template, will give you an instance of I<Template> object.
       template->process("my_template.html.tt", { title => "Hello World" });

=cut

# we need to find a way to get rid of this as we just
# use it for common_email template
sub template {
    my $what = shift || 'template';
    if (not $template_config->{template}) {
        $template_config->{template} = _configure_template_for(request());
    }
    return $template_config->{$what};
}

=head2 localize

It handles following cases for localization and returns localized string

 - basic string
   localize('Barriers must be on either side of the spot.')

 - string with parameters
   localize('Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.', 10)

 - simple array ref (message_to_client)
   localize(['Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.', 10])

 - nested array ref, params also need translations (longcode)
   localize(['Win payout if [_3] is strictly lower than [_6] at [_5].', 'USD', '166.27', 'GBP/USD', [], ['close on [_1]', '2016-05-13'], ['entry spot']])

=cut

sub localize {
    my ($content, @params) = @_;

    return '' unless $content;

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    my $lh = BOM::Platform::Context::I18N::handle_for($language)
        || die("could not build locale for language $language");

    my @texts = ();
    if (ref $content eq 'ARRAY') {
        return '' unless scalar @$content;
        # first one is always text string
        push @texts, shift @$content;
        # followed by parameters
        foreach my $elm (@$content) {
            # some params also need localization (longcode)
            if (ref $elm eq 'ARRAY' and scalar @$elm) {
                push @texts, $lh->maketext(@$elm);
            } elsif (ref $elm eq 'HASH') {
                my $l = $elm->{class}->new(
                    interval => $elm->{value},
                    locale   => lc $language
                );
                push @texts, $l->as_string;
            } else {
                push @texts, $elm;
            }
        }
    } else {
        @texts = ($content, @params);
    }

    return $lh->maketext(@texts);
}

sub _configure_template_for {
    my $request = shift;

    my @include_path = ($request->brand->template_dir);

    my $template_toolkit = Template::AutoFilter->new({
            ENCODING     => 'utf8',
            INCLUDE_PATH => join(':', @include_path),
            INTERPOLATE  => 1,
            PRE_CHOMP    => $Template::CHOMP_GREEDY,
            POST_CHOMP   => $Template::CHOMP_GREEDY,
            TRIM         => 1,
        }) || die "$Template::ERROR\n";

    return $template_toolkit;
}

sub _configure_for_request {
    my $request = shift;

    BOM::Config::Runtime->instance->app_config->check_for_update();
    #Lazy initialization of few params
    $template_config = {};

    return $request;
}

1;
