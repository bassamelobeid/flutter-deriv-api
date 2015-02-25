#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use File::Path ();
use Path::Tiny;
use JSON;

use f_brokerincludeall;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Database::DAO::AttorneyGranter;
use BOM::Platform::Sysinit ();
use BOM::Platform::Client::Attorney;
BOM::Platform::Sysinit::init();

my $logger = get_logger;
$logger->debug(sub { Dump(request()->params) });

sub log_attorney_action {
    my %args   = @_;
    my $logger = get_logger;
    $logger->info("STAFF:$args{staff}"
            . ($args{comment} ? ",GRANTER:$args{granter}" : '')
            . ",ATTORNEY:$args{attorney},ACTION:$args{action}"
            . ($args{comment} ? ",$args{comment}" : ''));
}

PrintContentType();

BrokerPresentation('Attorneys & Granters');

my $broker = request()->broker->code;
my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};

if ($broker eq 'FOG') {
    $broker = request()->broker->code;
    if ($broker eq 'FOG') {
        print "NOT RELEVANT FOR BROKER CODE FOG";
        code_exit_BO();
    }
}

my $action = request()->param('action');

if ($action eq 'show_attorneys') {
    my $attorneys = BOM::Database::DAO::AttorneyGranter::get_attorneys({'broker' => $broker});

    Bar('All Attorneys in DB');

    BOM::Platform::Context::template->process(
        'backoffice/attorneys.html.tt',
        {
            attorneys => $attorneys,
        });
} elsif ($action eq 'add_attorney') {
    my ($loginid, $company_name, $url, $approved) = map {
        my $param = request()->param($_);
        $param =~ s/^\s+//;
        $param =~ s/\s+$//;
        length $param ? $param : undef;
    } qw/loginid company_name url approved/;

    my $attorney;

    # Loginids must match ^[A-Z]+[0-9]+$
    # See BOM::Platform::Context::Request::_build_broker_code.
    $loginid = uc $loginid;

    if (!($attorney = BOM::Platform::Client::get_instance({loginid => $loginid}))) {
        print JSON::to_json({'error' => "Client $loginid does not exist"});
    } elsif (
        my $row = BOM::Database::DAO::AttorneyGranter::create_or_update_attorney({
                attorney     => $attorney,
                company_name => $company_name,
                url          => $url,
                approved     => $approved,
                no_exception => 1,
            }))
    {
        print JSON::to_json({
            success => 1,
            broker  => $attorney->broker,
            %$row,
        });
        log_attorney_action(
            staff    => $clerk,
            attorney => $loginid,
            action   => 'Add Attorney',
            comment  => "(url: $url, company: $company_name, approved: $approved)",
        );
    } else {
        print JSON::to_json({'error' => "Cannot create or update attorney $loginid"});
    }
} elsif ($action eq 'del_attorney') {
    my $loginid = request()->param('loginid');
    $loginid =~ s/^\s+//;
    $loginid =~ s/\s+$//;

    my $attorney;

    if (!($attorney = BOM::Platform::Client::get_instance({loginid => $loginid}))) {
        print JSON::to_json({'error' => "Client $loginid does not exist"});
    } elsif (
        my $row = BOM::Database::DAO::AttorneyGranter::delete_attorney({
                attorney => $attorney,
            }))
    {
        File::Path::remove_tree(
            BOM::Platform::Runtime->instance->app_config->system->directory->db
                . "/attorney_granters/"
                . $attorney->broker
                . "/letter_of_attorney/$loginid",
            {error => \my $err});
        if (@$err) {
            get_logger->error("while deleting attorney $loginid:");
            for my $e (@$err) {
                my ($fn, $msg) = %$e;
                get_logger->error($fn ? "  cannot unlink $fn: $msg\n" : "  $msg\n");
            }
        }
        print JSON::to_json({
            success => 1,
            broker  => $attorney->broker,
            %$row,
        });
        log_attorney_action(
            staff    => $clerk,
            attorney => $loginid,
            action   => 'Delete Attorney',
        );
    } else {
        print JSON::to_json({'error' => "Cannot delete attorney $loginid"});
    }
} elsif ($action eq 'show_granters') {
    my $attorney_client_loginid = request()->param('attorney_client_loginid');

    if ($attorney_client_loginid) {
        my $attorney = BOM::Platform::Client::Attorney->new({loginid => $attorney_client_loginid});
        my $attorney_as_client = $attorney->client;

        if ($attorney_as_client) {
            Bar(      'All Granters for Attorney ('
                    . $attorney_as_client->first_name . ' '
                    . $attorney_as_client->last_name . ' - '
                    . $attorney_client_loginid
                    . ')');

            BOM::Platform::Context::template->process(
                'backoffice/attorney_granters.html.tt',
                {
                    'attorney_client_loginid' => $attorney_client_loginid,
                    'granters'                => $attorney ? [$attorney->attorney_granter] : '',
                });
        } else {
            Bar('Invalid attorney (' . $attorney_client_loginid . ')');
        }
    }
} elsif ($action eq 'add_granters') {
    my $attorney_client_loginid                                    = request()->param('attorney_client_loginid');
    my $granter_loginid                                            = request()->param('granter_loginid');
    my $ignore_letter_of_attorney_and_use_granter_loginids_instead = request()->param('ignore_letter_of_attorney_and_use_granter_loginids_instead');

    my $attorney = BOM::Platform::Client::get_instance({'loginid' => $attorney_client_loginid});
    if (not $attorney) {
        print '<p>Error. Attorney is not exists [' . $attorney_client_loginid . ']</p>';
        code_exit_BO();
    }

    my @granters;
    if ($ignore_letter_of_attorney_and_use_granter_loginids_instead) {
        @granters = map { $_ =~ s/\s+//g; $_ } split(/\n/, $ignore_letter_of_attorney_and_use_granter_loginids_instead);
    } else {
        # This is ugly. We need to reinitialize the cgi object because we messed up
        # the upload field in subs_init. CGI.pm, however, will not read the input again
        # (even if it could). It simply reinitializes from global variables.
        my $cgi                    = CGI->new;
        my $letter_of_attorney_pdf = $cgi->param('letter_of_attorney_pdf');

        unless ($letter_of_attorney_pdf =~ /(?i)([0-9a-z]+)\.pdf$/) {
            print '<p>Error. We only accept pdf format</p>';
            code_exit_BO();
        }

        my $loginid = $granter_loginid || uc $1;

        my $granter = BOM::Platform::Client::get_instance({'loginid' => $loginid});

        if (not $granter) {
            print '<p>Error. Client (' . $loginid . ') does not exist.</p>';
            code_exit_BO();
        }

        push @granters, $loginid;

        # NOTE: $broker and $attorney->broker may differ. The letter directory depends on the
        # attorney's broker code not on the broker code this script is called with.
        my $letter_of_attorney_dir =
            (     BOM::Platform::Runtime->instance->app_config->system->directory->db
                . "/attorney_granters/"
                . $attorney->broker
                . "/letter_of_attorney/$attorney_client_loginid");

        if (not -d $letter_of_attorney_dir) {
            Path::Tiny::path($letter_of_attorney_dir)->mkpath;
        }

        my $letter_filename = "$letter_of_attorney_dir/$loginid.pdf";

        unless (rename $cgi->tmpFileName($letter_of_attorney_pdf), $letter_filename) {
            require Errno;
            if ($! == Errno::EXDEV()) {
                require File::Copy;
                File::Copy::copy($cgi->tmpFileName($letter_of_attorney_pdf), $letter_filename)
                    or die "[$0] could not write to $letter_filename $!";
            } else {
                die "[$0] could not write to $letter_filename $!";
            }
        }
    }

    if (
        my $result = BOM::Database::DAO::AttorneyGranter::create_or_update_attorney_granter({
                attorney         => $attorney,
                granter_loginids => \@granters,
                no_exception     => 1,
            }))
    {
        my %map = (
            insert => 'Added',
            update => 'Updated'
        );
        for my $granter_loginid (sort keys %$result) {
            my $res = $result->{$granter_loginid};
            print '<p><b>OK. '
                . ($map{$res} // 'If you see this, something strange has happened. Not sure if I added/updated') . ' ('
                . $granter_loginid
                . ') as granter of attorney '
                . $attorney->first_name . ' '
                . $attorney->last_name . '('
                . $attorney->loginid
                . ').</b></p>';
            log_attorney_action(
                staff    => $clerk,
                granter  => $granter_loginid,
                attorney => $attorney->loginid,
                action   => 'AddGranters'
            );
        }
        print '<input type="hidden" id="added_attorney_id" value="'
            . $attorney->loginid . '" />'
            . '<input type="hidden" id="added_attorney_total_granters" value="'
            . BOM::Database::DAO::AttorneyGranter::get_number_of_granters({
                attorney_client_loginid => $attorney->loginid,
                broker                  => $attorney->broker,
            }) . '" />';
    } else {
        print '<p>Error. Having problem to insert/update attorney granter.</p>';
    }
} elsif ($action eq 'change_status') {
    my $status                  = request()->param('status');
    my $attorney_client_loginid = request()->param('attorney_client_loginid');
    my $granter_loginid         = request()->param('granter_loginid');

    if ($status =~ /^(approved|disapproved)$/) {
        $status = $status eq 'approved' ? 1 : 0;
    } else {
        die 'invalid status for attorney_granter [' . $status . ']';
    }

    if (
        BOM::Database::DAO::AttorneyGranter::create_or_update_attorney_granter({
                attorney         => BOM::Platform::Client->new({loginid => $attorney_client_loginid}),
                granter_loginids => [$granter_loginid],
                approved         => $status,
            }))
    {
        print JSON::to_json(
            {'success' => 'Granter (' . $granter_loginid . ') of attorney (' . $attorney_client_loginid . ') ' . request()->param('status')});
        log_attorney_action(
            staff    => $clerk,
            granter  => $granter_loginid,
            attorney => $attorney_client_loginid,
            action   => ($status ? 'Approve' : 'Disapprove'),
        );
    } else {
        print JSON::to_json({'error' => 'Error occured to approve (' . $granter_loginid . ') of attorney (' . $attorney_client_loginid . ').'});
    }
} elsif ($action eq 'delete_granter') {
    my $attorney_client_loginid = request()->param('attorney_client_loginid');
    my $granter_loginid         = request()->param('granter_loginid');

    my $attorney = BOM::Platform::Client->new({loginid => $attorney_client_loginid});
    if (!$attorney) {
        print "<h1>$attorney_client_loginid is not an attorney or has no granters.</h1>";
    } elsif (
        BOM::Database::DAO::AttorneyGranter::delete_attorney_granter({
                attorney         => $attorney,
                granter_loginids => [$granter_loginid],
            }))
    {
        unlink(   BOM::Platform::Runtime->instance->app_config->system->directory->db
                . "/attorney_granters/"
                . $attorney->broker
                . "/letter_of_attorney/$attorney_client_loginid/$granter_loginid.pdf");
        print "<h1>Granter $granter_loginid removed from attorney $attorney_client_loginid.</h1>";
        log_attorney_action(
            staff    => $clerk,
            granter  => $granter_loginid,
            attorney => $attorney_client_loginid,
            action   => 'Delete',
        );
    } else {
        print "<h1>Error occurred while removing granter $granter_loginid from attorney $attorney_client_loginid</h1>";
    }

    print '<p>Redirecting in 1 seconds... or <a href="'
        . request()->url_for(
        'backoffice/attorney_granter.cgi',
        {
            broker                  => $broker,
            action                  => "show_granters",
            attorney_client_loginid => $attorney_client_loginid
        })
        . '">go back</a> <script>setTimeout(function(){window.location.href=\''
        . request()->url_for(
        'backoffice/attorney_granter.cgi',
        {
            broker                  => $broker,
            action                  => "show_granters",
            attorney_client_loginid => $attorney_client_loginid
        }) . '\';},1000);</script></p>';
} else {
    die 'invalid action [' . $action . '] for attorney_granter';
}

code_exit_BO();
