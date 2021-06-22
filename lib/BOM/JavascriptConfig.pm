package BOM::JavascriptConfig;
use strict;
use warnings;

use MooseX::Singleton;
use Mojo::URL;

use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);

sub bo_js_files_for {
    my $self = shift;
    my $page = shift;

    my @js_files = (
        'external/jquery-3.1.1.min.js',   'external/jquery-ui.min.js', 'external/sortable.js', 'external/jquery.form.js',
        'external/jquery.jsonify-0.1.js', 'backoffice_new.js?v=2021-06-20'
    );
    for ($page) {
        push @js_files, 'bbdl.js' if /f_bet_iv/;
        push @js_files, 'risk_dashboard.js', 'external/jbpivot.min.js', 'external/raphael-min.js', 'external/jquery.sparkline.min.js'
            if /risk_dashboard/;
        push @js_files, 'external/Duo-Web-v1.bundled.min.js'
            if /second_step_auth/;
        push @js_files, 'external/select2.min.js' if /promocode_edit/;
        push @js_files, 'external/jstree/jquery.jstree.js', 'pricing_details.js',
            'external/highcharts/highstock.js', 'external/highcharts/export-csv.js', 'external/highcharts/highstock-exporting.js',
            if /(bpot|f_bet_iv)/;
        push @js_files, 'external/syntaxhighlighter/shCore.js',
            'external/syntaxhighlighter/shAutoloader.js', 'external/syntaxhighlighter/shBrushYaml.js'
            if /view_192_raw_response/;
        push @js_files, 'external/excellentexport.min.js'
            if /f_manager_crypto/;
    }

    return map { request()->url_for('js/' . $_) } @js_files;
}

1;
