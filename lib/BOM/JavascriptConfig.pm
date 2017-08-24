package BOM::JavascriptConfig;
use strict;
use warnings;

use MooseX::Singleton;
use Mojo::URL;

use BOM::Platform::Runtime;

sub bo_js_files_for {
    my $self = shift;
    my $page = shift;

    my @js_files = (
        'external/jquery-3.1.1.min.js',   'external/jquery-ui.min.js', 'external/sortable.js', 'external/jquery.form.js',
        'external/jquery.jsonify-0.1.js', 'backoffice.js'
    );
    for ($page) {
        push @js_files, 'bbdl.js' if /f_bet_iv/;
        push @js_files, 'risk_dashboard.js', 'external/jbpivot.min.js', 'external/raphael-min.js', 'external/treemap-squared-0.5.min.js'
            if /risk_dashboard/;
        push @js_files, 'external/Duo-Web-v1.bundled.min.js'
            if /second_step_auth/;
        push @js_files, 'external/select2.min.js' if /promocode_edit/;
        push @js_files, 'external/jstree/jquery.jstree.js', 'pricing_details.js',
            'external/highcharts/highstock.js', 'external/highcharts/export-csv.js', 'external/highcharts/highstock-exporting.js',
            if /bpot/;
        push @js_files, 'external/jstree/jquery.jstree.js',
            'external/highcharts/highstock.js', 'external/highcharts/export-csv.js', 'external/highcharts/highstock-exporting.js',
            if /dailyico/;
        push @js_files, 'external/syntaxhighlighter/shCore.js',
            'external/syntaxhighlighter/shAutoloader.js', 'external/syntaxhighlighter/shBrushYaml.js'
            if /view_192_raw_response/;
        push @js_files, 'external/excellentexport.min.js'
            if /f_manager_crypto/;
        push @js_files, 'external/jquery.sparkline.min.js'
            if /risk_dashboard/;
    }

    my $base_dir = Mojo::URL->new(BOM::Platform::Runtime->instance->app_config->cgi->backoffice->static_url);
    $base_dir->path('javascript/');
    return map { $base_dir->to_string . $_ } @js_files;
}

1;
