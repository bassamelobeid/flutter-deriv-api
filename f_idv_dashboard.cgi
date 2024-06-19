#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel );
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::IdentityVerification;
use Date::Utility;
use Text::CSV;
use Syntax::Keyword::Try;
use Log::Any qw($log);

BOM::Backoffice::Sysinit::init();
my $schema = [{
        field => q{loginids},
        th    => q{Loginids},
    },
    {
        field => q{issuing_country},
        th    => q{Country}
    },
    {
        field => q{document_type},
        th    => q{Document Type}
    },
    {
        field => q{document_number},
        th    => q{Document Number}
    },
    {
        field => q{provider},
        th    => q{Provider}
    },
    {
        field => q{status},
        th    => q{Status}
    },
    {
        field => q{status_messages},
        th    => q{Messages}
    },
    {
        field => q{submitted_at},
        th    => q{Timestamp}
    },
    {
        field    => q{request},
        th       => q{Request},
        skip_csv => 1,
    },
    {
        field    => q{response},
        th       => q{Response},
        skip_csv => 1,
    },
    {
        field    => q{report},
        th       => q{report},
        skip_csv => 1,
    },
    {
        field    => q{photo_urls},
        th       => q{pictures},
        skip_csv => 1,
    }];

my %input = %{request()->params};
$input{date_from} //= Date::Utility->new()->minus_months(1)->date_yyyymmdd;
$input{date_to}   //= Date::Utility->new()->date_yyyymmdd;
my $dashboard;

# we will grab data before presentation just in case we need
# to serve a CSV file instead of html.

my $valid_request;

if (request()->http_method eq 'POST') {
    try {
        my $drf = Date::Utility->new($input{date_from});
        my $drt = Date::Utility->new($input{date_to});

        if ($drf->is_after($drt)) {
            die 'Invalid date range';
        }

        $valid_request = 1;
    } catch ($e) {
        $log->warn('Invalid date attempted');
    }

    if ($valid_request) {
        $dashboard = BOM::Backoffice::IdentityVerification::get_dashboard(%input);

        if ($input{csv}) {
            PrintContentType_excel('idv_dashboard.csv');
            my $csv = Text::CSV->new({
                    binary       => 1,
                    always_quote => 1,
                    quote_char   => '"',
                    eol          => "\n"
                }) or die "Cannot use CSV: " . Text::CSV->error_diag();

            my @header = map { $_->{skip_csv} ? () : $_->{th} } $schema->@*;
            $csv->combine(@header);
            print $csv->string;

            for my $row ($dashboard->@*) {
                my @row_array = map { $_->{skip_csv} ? () : $row->{$_->{field}} // 'N/A' } $schema->@*;
                $csv->combine(@row_array);
                print $csv->string;
            }

            code_exit_BO();
        }
    }
}

PrintContentType();
BrokerPresentation("IDV DASHBOARD");
Bar("FILTER IDV REQUESTS");

my $filter_data = BOM::Backoffice::IdentityVerification::get_filter_data();

my ($idv_countries, $idv_document_types, $idv_providers, $idv_statuses, $idv_messages) = @{$filter_data}{
    qw/
        countries
        document_types
        providers
        statuses
        messages
        /
};

BOM::Backoffice::Request::template()->process(
    'backoffice/idv/filters.html.tt',
    {
        url            => request()->url_for('backoffice/f_idv_dashboard.cgi'),
        providers      => $idv_providers,
        countries      => $idv_countries,
        document_types => $idv_document_types,
        statuses       => $idv_statuses,
        messages       => $idv_messages,
        title          => '',
        offset         => $input{offset} // 0,
        filters        => +{%input}});

if (request()->http_method eq 'POST') {
    Bar("IDV REQUESTS");
    $dashboard //= [];

    my $records = scalar @$dashboard;
    my $limit   = +BOM::Backoffice::IdentityVerification::PAGE_LIMIT;

    splice(@$dashboard, $limit);

    BOM::Backoffice::Request::template()->process(
        'backoffice/idv/dashboard.html.tt',
        {
            dashboard     => $dashboard,
            increment     => $limit + 1 == $records ? $limit : 0,
            offset        => $input{offset} // 0,
            decrement     => $limit,
            schema        => $schema,
            valid_request => $valid_request,
        });
}

code_exit_BO();
