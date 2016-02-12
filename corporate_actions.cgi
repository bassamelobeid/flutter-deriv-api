#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use Quant::Framework::CorporateAction;
use BOM::Platform::Runtime;
use JSON qw(to_json);
use BOM::Platform::Plack qw( PrintContentType_JSON );
use CGI;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

my $cgi     = CGI->new;
my $symbol  = $cgi->param('symbol');
my $comment = $cgi->param('comment');
my $id      = $cgi->param('action_id');
my $enable  = $cgi->param('enable');

my $response;
try {
    my $corp = Quant::Framework::CorporateAction->new(symbol => $symbol,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer()
    );
    my $action_to_update = $corp->actions->{$id};
    $action_to_update->{comment} = $comment;
    if ($enable) {
        $action_to_update->{enable}          = $enable;
        $action_to_update->{suspend_trading} = 0;
    }
    $action_to_update->{flag} = 'U';
    $corp->save;

    # changed dynamic settings
    my $disabled = BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions || [];

    my @new_list = grep { $_ ne $symbol } @$disabled;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions(\@new_list);
    BOM::Platform::Runtime->instance->app_config->save_dynamic;

    $response->{success} = 1;
    $response->{id}      = $id;
}
catch {
    $response->{success} = 0;
    $response->{reason}  = $_;
};

PrintContentType_JSON();
print to_json($response);
code_exit_BO();
