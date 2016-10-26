package BOM::Backoffice::Request;

use feature 'state';

use base qw( Exporter );
use Template;
use Template::Stash;
use Format::Util::Numbers;

our @EXPORT_OK = qw(request localize template);

use BOM::Platform::Runtime;
use BOM::Platform::Context::I18N;
use BOM::Backoffice::Request::Base;

state $current_request;

sub request {
    my $new_request = shift;
    state $default_request = BOM::Backoffice::Request::Base->new();
    $current_request = _configure_for_request($new_request) if ($new_request);
    return $current_request // $default_request;
}

sub request_completed {
    $current_request = undef;
    _configure_for_request(request());
    return;
}

sub _configure_for_request {
    my $request = shift;
    BOM::Platform::Runtime->instance->app_config->check_for_update();
    return $request;
}

# need to update this sub to get language as input, as of now
# language is always EN for backoffice
sub localize {
    my @texts = @_;

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    my $lh = BOM::Platform::Context::I18N::handle_for($language)
        || die("could not build locale for language $language");

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
    if (not $template_config->{template}) {
        $template_config->{stash} = _configure_template_stash_for(request());
        $template_config->{template} = _configure_template_for(request(), $template_config->{stash});
    }
    return $template_config->{$what};
}

sub _configure_template_stash_for {
    my $request = shift;
    return Template::Stash->new({
        runtime                   => BOM::Platform::Runtime->instance,
        language                  => $request->language,
        request                   => $request,
        broker_name               => 'Binary.com',
        l                         => \&localize,
        to_monetary_number_format => \&Format::Util::Numbers::to_monetary_number_format,
    });
}

sub _configure_template_for {
    my $request = shift;
    my $stash   = shift;

    my @include_path = ('/home/git/regentmarkets/bom-backoffice/templates/', '/home/git/regentmarkets/bom-platform/templates/');

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

1;
