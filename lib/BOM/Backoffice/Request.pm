package BOM::Backoffice::Request;

use strict;
use warnings;

use feature 'state';

use Exporter qw(import export_to_level);

use Template::AutoFilter;
use Template::Stash;
use Format::Util::Numbers;

our @EXPORT_OK = qw(request localize template);

use Time::Duration::Concise::Localize;
use BOM::Config::Runtime;
use BOM::Platform::Context::I18N;
use BOM::Backoffice::Request::Base;

# Represents the currently-active request, and should be cleared in L</request_completed>
# as soon as the request finishes.
my $current_request;
# Holds information used by TT2 processing, and should also be cleared in L</request_completed>
# after the current request.
my $template_config;

sub request {
    my $new_request = shift;
    state $default_request = BOM::Backoffice::Request::Base->new();
    $current_request = _configure_for_request($new_request) if ($new_request);
    return $current_request // $default_request;
}

sub request_completed {
    $current_request = undef;
    $template_config = undef;
    _configure_for_request(request());
    return;
}

sub _configure_for_request {
    my $request = shift;
    BOM::Config::Runtime->instance->app_config->check_for_update();
    return $request;
}

# need to update this sub to get language as input, as of now
# language is always EN for backoffice
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

=head2 template

Correct instance of template_toolkit object for current request.

usage,
    template, will give you an instance of I<Template> object.
       template->process("my_template.html.tt", { title => "Hello World" });

    template("stash"), will give you an instance of I<Template::Stash> object. This contians all default variables defined for processing template.
        template("stash")->update({ title => 'Hello World'});

=cut

sub template {
    my $what = shift || 'template';
    $template_config->{stash} ||= _configure_template_stash_for(request());
    $template_config->{template} ||= _configure_template_for($template_config->{stash});
    return $template_config->{$what};
}

sub _configure_template_stash_for {
    my $request = shift;
    return Template::Stash->new({
        runtime      => BOM::Config::Runtime->instance,
        language     => $request->language,
        request      => $request,
        broker_name  => ucfirst BOM::Config::domain()->{default_domain},
        l            => \&localize,
        formatnumber => \&Format::Util::Numbers::formatnumber
    });
}

sub _configure_template_for {
    my $stash = shift;

    my @include_path = ('/home/git/regentmarkets/bom-backoffice/templates/');

    my $template_toolkit = Template::AutoFilter->new({
            ENCODING     => 'utf8',
            INCLUDE_PATH => join(':', @include_path),
            INTERPOLATE  => 1,
            PRE_CHOMP    => $Template::CHOMP_GREEDY,
            POST_CHOMP   => $Template::CHOMP_GREEDY,
            TRIM         => 1,
            STASH        => $stash,
        }) || die "$Template::ERROR\n";

    return $template_toolkit;
}

1;
