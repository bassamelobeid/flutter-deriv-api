package BOM::Platform::Context;

=head1 NAME

BOM::Platform::Context

=head1 DESCRIPTION

A plain old perl module, containing all functions for current execution context and all variables in the current context.

=cut

use strict;
use warnings;

use feature 'state';
use Scalar::Util qw(weaken);
use Template;
use Template::Stash;
use base qw( Exporter );

our @EXPORT_OK = qw( request runtime localize app_config template);

use BOM::Platform::Runtime;
use BOM::Platform::Context::Request;
use Format::Util::Numbers;
use BOM::Platform::Context::I18N;
use Path::Tiny;

state $current_request;
state $template_config = {};
state $timer;

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

=head2 request_completed

Marks completion of the request.

=cut

sub request_completed {
    $current_request = undef;
    _configure_for_request(request());
    return;
}

=head2 runtime

The object representing the whole runtime.

=cut

sub runtime {
    return BOM::Platform::Runtime->instance;
}

=head2 app_config

App config for the current request.

=cut

sub app_config {
    return BOM::Platform::Runtime->instance->app_config;
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
    if (not $template_config->{template}) {
        $template_config->{stash} = _configure_template_stash_for(request());
        $template_config->{template} = _configure_template_for(request(), $template_config->{stash});
    }
    return $template_config->{$what};
}

=head2 localize

Returns the localized verion of the provided string, with argument

=cut

sub localize {
    my @texts    = @_;
    my $language = 'EN';
    my $website  = runtime()->website_list->default_website;
    my $version  = runtime()->website_list->default_website->config->get('static.version');

    if (my $request = request()) {
        $language = $request->language;
        $website  = $request->website;
        $version  = $website->config->get('static.version');
    }

    my $lh = BOM::Platform::Context::I18N::handle_for($language, $website, $version)
        || die("could not build locale for language $language, static-version $version, website " . $website->name);

    return $lh->maketext(@texts);
}

sub _configure_template_stash_for {
    my $request = shift;
    return Template::Stash->new({
        runtime                   => BOM::Platform::Runtime->instance,
        language                  => $request->language,
        broker                    => $request->broker,
        request                   => $request,
        broker_name               => $request->website->display_name,
        website                   => $request->website,
        'is_pjax_request'         => $request->is_pjax,
        l                         => \&localize,
        to_monetary_number_format => \&Format::Util::Numbers::to_monetary_number_format,
    });
}

sub _configure_template_for {
    my $request = shift;
    my $stash   = shift;

    my @include_path;
    if ($request->backoffice) {
        push @include_path, '/home/git/regentmarkets/bom-backoffice/templates/';
    }

    push @include_path, path($request->website->static_path)->child('templates', 'toolkit');

    my $template_toolkit = Template->new({
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

sub _configure_for_request {
    my $request = shift;

    BOM::Platform::Runtime->instance->app_config->check_for_update();
    $request->website->rebuild_config();
    #Lazy initialization of few params
    $template_config = {};
    $timer           = undef;

    return $request;
}

1;
