package BOM::JavascriptConfig;

use MooseX::Singleton;
use Mojo::URL;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;

sub binary_js {
    return 'https://www.binary.com/js/binary.min.js';
}

sub bo_js_files_for {
    my $self = shift;
    my $page = shift;

    my @js_files = ('external/sortable.js', 'external/jquery.form.js', 'external/jquery.jsonify-0.1.js', 'backoffice.js');
    for ($page) {
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

1;
