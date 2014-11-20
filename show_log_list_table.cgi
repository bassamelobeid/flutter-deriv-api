#!/usr/bin/perl
package main;

use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Persistence::DAO::Utils::Log;
use f_brokerincludeall;
system_initialize();

PrintContentType();

BrokerPresentation("SHOW LOG");
BOM::Platform::Auth0::can_access(['CS']);
my $broker = request()->broker->code;

if ($broker eq 'FOG') {
    $broker = request()->broker->code;
    if ($broker eq 'FOG') {
        print "NOT RELEVANT FOR BROKER CODE FOG";
        code_exit_BO();
    }
}

my $pages;
my $table_name     = request()->param('category');
my $loginid        = request()->param('loginid');
my $page           = request()->param('page') ? request()->param('page') : 0;
my $number_of_rows = request()->param('number_of_rows') ? request()->param('number_of_rows') : 10;

my $title_bar;
my $title_bar_page_number = $page + 1;

if ($loginid) {
    $title_bar = "Log ($table_name) on Client ($loginid) - Page ($title_bar_page_number)";
} else {
    $title_bar = "Log ($table_name) on Broker ($broker) - Page ($title_bar_page_number)";
}

Bar($title_bar);

my $url_to_client;
if ($loginid) {
    $url_to_client = request()->url_for(
        "backoffice/f_clientloginid_edit.cgi",
        {
            broker  => $broker,
            loginID => $loginid
        });
} else {
    $url_to_client = request()->url_for("backoffice/f_clientloginid.cgi", {broker => $broker});
}

my $url_to_myself = request()->url_for(
    "backoffice/show_log_list_table.cgi",
    {
        broker   => $broker,
        category => $table_name
    });
my $result_arrayref;

if ($table_name =~ /^client_status_(\w+)/) {
    my $status_code = $1;

    if (not BOM::Platform::Client->client_status_types->{$status_code}) {
        print "Invalid category [$table_name]";
        code_exit_BO();
    }

    my $total_count = BOM::Platform::Persistence::DAO::Utils::Log::get_count_client_status_log_by_status_code({
            'status_code' => $status_code,
            'broker'      => $broker,
    });

    $pages = int $total_count / $number_of_rows;
    $pages -= 1 if ($total_count % $number_of_rows == 0);

    $result_arrayref = BOM::Platform::Persistence::DAO::Utils::Log::get_sorted_arrayref_list_of_client_status_log_by_status_code({
            'status_code'    => $status_code,
            'broker'         => $broker,
            'page'           => $page,
            'number_of_rows' => $number_of_rows,
    });
} else {
    if ($loginid) {
        my $total_count = BOM::Platform::Persistence::DAO::Utils::Log::get_count_log_by_table_name_and_loginid({
                'table_name' => $table_name,
                'broker'     => $broker,
                'loginid'    => $loginid
        });
        $pages = int $total_count / $number_of_rows;
        $pages -= 1 if ($total_count % $number_of_rows == 0);

        $result_arrayref = BOM::Platform::Persistence::DAO::Utils::Log::get_sorted_arrayref_list_of_log_by_table_name_and_loginid({
                'table_name'     => $table_name,
                'broker'         => $broker,
                'page'           => $page,
                'number_of_rows' => $number_of_rows,
                'loginid'        => $loginid
        });

        $url_to_myself .= "&loginid=$loginid";
    } else {
        my $total_count = BOM::Platform::Persistence::DAO::Utils::Log::get_count_log_by_table_name({
                'table_name' => $table_name,
                'broker'     => $broker,
        });
        $pages = int $total_count / $number_of_rows;
        $pages -= 1 if ($total_count % $number_of_rows == 0);

        $result_arrayref = BOM::Platform::Persistence::DAO::Utils::Log::get_sorted_arrayref_list_of_log_by_table_name({
                'table_name'     => $table_name,
                'broker'         => $broker,
                'page'           => $page,
                'number_of_rows' => $number_of_rows,
        });
    }
}

my @logs = map { $_->{'log_details'} = JSON::from_json($_->{'log_detail'}); $_; } @{$result_arrayref};

# Template parameters preparation
my $template_param;

$template_param->{'table_headers'}  = ['Date', 'Clerk', 'LoginID', 'Table', 'Detail'];
$template_param->{'logs'}           = \@logs;
$template_param->{'pages'}          = $pages;
$template_param->{'next'}           = $page < $pages ? $page + 1 : $page;
$template_param->{'prev'}           = $page > 0 ? $page - 1 : $page;
$template_param->{'number_of_rows'} = $number_of_rows;
$template_param->{'url_to_myself'}  = $url_to_myself;
$template_param->{'url_to_client'}  = $url_to_client;

BOM::Platform::Context::template->process('backoffice/log_list_table.html.tt', $template_param) || die BOM::Platform::Context::template->error(),
  "\n";

code_exit_BO();
