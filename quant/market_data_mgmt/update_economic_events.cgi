#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use Quant::Framework::EconomicEventCalendar;
use BOM::Platform::Chronicle;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

## Delete economic event

my $delete_event           = request()->param('delete_event');
my $event_id               = request()->param('event_id');

if ($delete_event) {
    unless ($event_id) {
        print "Error: ID is not found.";
        code_exit_BO();
    }
warn "I am in here";
    my $deleted = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    )->delete_event({id => $event_id});;
    print ($deleted ? $event_id : 0);
}

