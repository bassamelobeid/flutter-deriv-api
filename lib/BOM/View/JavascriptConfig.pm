package BOM::View::JavascriptConfig;

use MooseX::Singleton;
use File::Temp;
use JSON qw(to_json decode_json);
use Encode;
use HTML::Entities;
use URI::Escape;
use DateTime;
use Digest::MD5;
use File::Slurp;
use Path::Tiny;
use Mojo::URL;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Static::Config;
use BOM::System::Config;

has '_js_dir_path' => (
    is      => 'rw',
    default => '',
);

sub config_for {
    my $self = shift;

    my $static_url = $self->static_url();
    my $libs       = [];
    push @$libs, map { "$static_url$_" } @{$self->_bom_static_js};

    my $config = {
        libs     => $libs,
        settings => $self->_setting(),
    };

    return $config;
}

sub bo_js_files_for {
    my $self = shift;
    my $page = shift;

    my @js_files = ('external/sortable.js', 'external/jquery.form.js', 'external/jquery.jsonify-0.1.js', 'backoffice.js');
    for ($page) {
        push @js_files, 'moneyness.js' if /f_moneyness_surface_comparison/;
        push @js_files, 'volsurface_calibration.js'
            if /f_volsurface_calibration/;
        push @js_files, 'bbdl.js' if /f_bet_iv/;
        push @js_files, 'risk_dashboard.js', 'external/jbpivot.min.js', 'external/raphael-min.js', 'external/treemap-squared-0.5.min.js'
            if /risk_dashboard/;
        push @js_files, 'external/Duo-Web-v1.bundled.min.js'
            if /second_step_auth/;
        push @js_files, 'external/select2.min.js' if /promocode_edit/;
        push @js_files, 'external/jstree/jquery.jstree.js', 'pricing_details.js'
            if /bpot/;
        push @js_files, 'external/syntaxhighlighter/shCore.js',
            'external/syntaxhighlighter/shAutoloader.js', 'external/syntaxhighlighter/shBrushYaml.js'
            if /view_192_raw_response/;
    }

    my $base_dir = Mojo::URL->new(BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url);
    $base_dir->path('javascript/');
    return map { $base_dir->to_string . $_ } @js_files;
}

sub from {
    my $class = shift;
    my $dir   = shift;
    my $self  = $class->instance;

    $self->_js_dir_path($dir);

    return $self;
}

sub _setting {
    my $self = shift;

    my $streaming_server = request()->domain_for({});
    if (request()->backoffice) {
        if (BOM::System::Config::node->{node}->{www2}) {
            $streaming_server = 'www2.binary.com';
        } elsif (BOM::System::Config::env =~ /^production$/) {
            $streaming_server = 'www.binary.com';
        }
    }

    my %setting = (
        enable_relative_barrier => 'true',
        image_link              => {
            hourglass     => request()->url_for('images/common/hourglass_1.gif')->to_string,
            up            => request()->url_for('images/javascript/up_arrow_1.gif')->to_string,
            down          => request()->url_for('images/javascript/down_arrow_1.gif')->to_string,
            calendar_icon => request()->url_for('images/common/calendar_icon_1.png')->to_string,
            livechaticon  => request()->url_for('images/pages/contact/chat-icon.svg')->to_string,
        },
        broker           => request()->broker->code,
        countries_list   => $self->_countries_list,
        valid_loginids   => join('|', map { $_->code } @{request()->website->broker_codes}),
        streaming_server => $streaming_server
    );

    foreach my $current_currency (@{request()->available_currencies}) {
        push @{$setting{arr_all_currencies}}, uc($current_currency);
    }

    return JSON::to_json(\%setting);
}

has [qw(_bom_static_js _countries_list)] => (
    is         => 'ro',
    lazy_build => 1,
);

has '_bom_js_compressed' => (
    is      => 'ro',
    default => '/compressed_binary',
);

sub _build__bom_static_js {
    my $self = shift;

    return ['js/binary.min.js?' . BOM::Platform::Static::Config::get_config()->{binary_static_hash}];
}

sub _build__countries_list {
    return BOM::Platform::Runtime->instance->countries_list;
}

sub static_url {
    return Mojo::URL->new(BOM::Platform::Static::Config::get_static_url())->to_string;
}

1;
