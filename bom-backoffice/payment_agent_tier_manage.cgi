#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use List::Util qw(max);

use constant AUDIT_LIMIT => 25;

my $cgi = CGI->new;

PrintContentType();
BrokerPresentation('PAYMENT AGENT TIER MANAGEMENT');

my %input  = request()->params->%*;
my $broker = request()->broker_code;
my %output;

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'write'
    })->db->dbic;

my $item;

if ($input{create}) {
    try {
        die "name is required\n" unless $input{name};
        $item = $db->run(
            fixup => sub {
                die "a tier named $input{name} already exists\n"
                    if $_->selectrow_array('SELECT * FROM betonmarkets.pa_tier_list(NULL) WHERE name=?', undef, $input{name});
                $_->do('SELECT * FROM betonmarkets.pa_tier_create(?,?,?,?,?)', undef, @input{qw(name cashier_withdraw p2p trading transfer_to_pa)});
                push $output{messages}->@*, "Tier '$input{name}' created";
            });
    } catch ($e) {
        push $output{errors}->@*, "Cannot create tier: $e";
    }
}

if (my $id = $input{edit}) {
    try {
        $output{item} = $db->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM betonmarkets.pa_tier_list(?)', undef, $id);
            }) or die 'tier not found';
    } catch ($e) {
        push $output{errors}->@*, "Cannot edit tier: $e";
    }
}

if ($input{save}) {
    try {
        $db->run(
            fixup => sub {
                $_->do('SELECT * FROM betonmarkets.pa_tier_update(?,?,?,?,?,?)',
                    undef, @input{qw(save name cashier_withdraw p2p trading transfer_to_pa)});
            });
        push $output{messages}->@*, "Tier '$input{name}' saved";
    } catch ($e) {
        push $output{errors}->@*, "Cannot save tier: $e";
    }
}

if (my $id = $input{delete}) {
    try {
        my $name = $db->run(
            fixup => sub {
                $_->selectrow_array('SELECT * FROM betonmarkets.pa_tier_delete(?)', undef, $id);

            });
        push $output{messages}->@*, "Tier '$name' deleted";
    } catch ($e) {
        push $output{errors}->@*, "Failed to delete tier: $e";
    }
}

$output{tiers} = $db->run(
    fixup => sub {
        $_->selectall_arrayref('SELECT * FROM betonmarkets.pa_tier_list(NULL)', {Slice => {}});
    });

if ($input{bulk_assign}) {
    my $file  = $cgi->upload('bulk_tier_file');
    my $lines = Text::CSV->new->getline_all($file);
    shift @$lines;    # skip header
    my %tiers_by_name = map { $_->{name} => $_->{id} } $output{tiers}->@*;

    for my $line (@$lines) {
        my ($loginid, $tier) = @$line;
        try {
            my $client = BOM::User::Client->new({loginid => $loginid}) or die "$loginid is not a valid loginid\n";
            my $pa     = $client->get_payment_agent                    or die "$loginid is not a payment agent\n";
            my $id     = $tiers_by_name{$tier}                         or die "Invalid tier $tier provided for PA $loginid\n";
            $pa->tier_id($id);
            $pa->save;
            push $output{messages}->@*, "Tier '$tier' assigned to PA $loginid";
        } catch ($e) {
            push $output{errors}->@*, $e;
        }
    }
}

my $audit_rows = $db->run(
    fixup => sub {
        $_->selectall_arrayref('SELECT * FROM betonmarkets.pa_tier_audit_history(?, ?)', {Slice => {}}, AUDIT_LIMIT + 1, $input{start} //= 0);
    });

for my $row (@$audit_rows) {
    my $change;
    if ($row->{operation} eq 'INSERT') {
        $change = 'Created';
    } elsif ($row->{operation} eq 'DELETE') {
        $change = 'Deleted';
    } elsif (my @changes = grep { $row->{$_} ne $row->{$_ . '_prev'} } qw(name cashier_withdraw p2p trading transfer_to_pa)) {
        $change = join ', ', map { $_ . ' changed from ' . $row->{$_ . '_prev'} . ' to ' . $row->{$_} } @changes;
    }

    push $output{audit}->@*,
        {
        id     => $row->{id},
        name   => $row->{name},
        stamp  => $row->{stamp},
        user   => $row->{pg_userid},
        change => $change
        }
        if $change;
}

BOM::Backoffice::Request::template()->process(
    'backoffice/payment_agent_tier_manage.tt',
    {
        %output,
        broker => $broker,
        $input{start}              ? (prev => max(0, $input{start} - AUDIT_LIMIT)) : (),
        @$audit_rows > AUDIT_LIMIT ? (next => $input{start} + AUDIT_LIMIT)         : (),
        audit_limit => AUDIT_LIMIT,
    });

code_exit_BO();
