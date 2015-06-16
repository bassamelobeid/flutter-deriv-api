package BOM::MarketData::Parser::Bloomberg::FileDownloader;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::FileDownloader

=head1 DESCRIPTION

A wrapper around our Bloomberg Data License access. This package's responsibility
is to fetch "raw" CSV files from BBDL and save them for further processing by
other classes/system components.

=head1 GENERAL INFORMATION

From Bloomberg:

London IPE Crude Oil futures
SECTYP=FUT_CHAIN AND SECURITY_DES=COX6 Comdty | MACRO

To get available futures on the FTSE index:
SECTYP=FUT_CHAIN AND SECURITY_DES=Z Z6 Comdty | MACRO

PX_LAST gives me the last price.  How do I get the date & time when that last price occurred?
Answer: Use LAST_UPDATE and LAST_UPDATE_DT. Also recommend PRICING_SOURCE so you know which provider the prices are from.

*********** !!IMPORTANT!! ***********
DO NOT USE THE MACRO FUNCTION! IT COSTS A FORTUNE IN BLOOMBERG COSTS!
THE JYSoptionsMACRO.req MACRO REQUEST FILE WOULD HAVE COST US$20,000 FOR A ONE-SHOT REQUEST!
*********** !!IMPORTANT!! ***********

=head2 Bloomberg Data License Contact Details

Tel +44-20-7330-7500 ask for an ETS technical Representative

Email: datalicense@bloomberg.net

Direct email of Technical Department: gts@bloomberg.net

Sales: our account executive is "TRACY SIMONE TAN, BLOOMBERG/ SINGAPORE" <ttan@bloomberg.net>

=head2 Notes About BBDL Server Restarts

Every night, the primary backend machines are "restarted" also known
as "turned around." The restart period is used for database updates, system
maintenance, and related tasks. The restart period depends on the region and
is broken down as follows:

North, Central, and South America: 22:00-00:00 ET

Europe, Middle East, and Africa: 22:00-00:00 ET (03:00-05:00 GMT)

Asia and Australia: 07:30-09:30 ET (21:30-23:30 JT)

These times are approximate and may very up to half an hour due to many other
dependent jobs. During restart, requests are sent to a backup backend machine
for processing. If a request is being processed and restart begins, the
request will be stopped and reprocessed after restart is complete. In order
to avoid this restart period, requests should be submitted well in advance to
allow completion of processing or submitted at a time well after to avoid any
interruption.

=head2 Notes About BBDL Request Files

1) The Bloomberg request files are automatically removed from the BBDL server after 7 days,
but they continue to be processed. So don't be surprised if you see them disappear
from the FTP directory.

2) To link a BBDL account to a terminal account, it can be done by amending the request
file header or requested Bloomberg technical support team to hard-coded from their end
for a permanent link. In our case, we choose to do it manually so that if anything goes
wrong, we can swift over easily to other terminal account by ourself.

3) Steps to manually link BBDL account to terminal account:

a) Add the following lines to the file header: USERNUMBER=, WS=, SN=

b) Those 3 numbers needed above can be located by enter IAM <GO> on the terminal.

- The number after "User" is the USERNUMBER

- The first part of the number following "S/N:" (i.e. the part before the hyphen) is the SN

- The second part of the "S/N:"(ie after the hyphen) is the WS number

3) This BBDL account is link to our company Bloomberg terminal account to take advantage of default setting on volsurface.

The company Bloomberg terminal account details are: Username: RTECHNOLOGY, Password: letmein

=cut

use Moose;
use Net::SFTP::Foreign;
use BOM::Utility::Log4perl qw( get_logger );
use Path::Tiny;

use Date::Utility;
use BOM::Market::UnderlyingDB;
use BOM::Platform::Runtime;
use BOM::Market::Types;
use Carp;
use BOM::MarketData::Parser::Bloomberg::RequestFiles;

=head1 ATTRIBUTES

=head2 data_dir

Directory to where raw CSV files should be saved.

=cut

has data_dir => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_data_dir {
    my $self = shift;

    my $loc = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/BBDL';
    path($loc)->mkpath if (not -e $loc);
    return $loc;
}

=head2 sftp_server_ips

List of all BBDL sftp server IPs. Preferred is first.

=cut

has sftp_server_ips => (
    is       => 'ro',
    isa      => 'ArrayRef',
    init_arg => undef,
    default  => sub {
        ['205.216.112.23', '208.22.57.176'];
    },
);

=head2 sftp_server_ip

The IP that we'll log into to perform all our BBDL operations.

=cut

#Note: Bloomberg wants us to use bfmrr.bloomberg.com,
#which is a random round-robin of both servers.
has sftp_server_ip => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_sftp_server_ip {
    my $self = shift;
    return $self->sftp_server_ips->[0];
}

=head2 volatility_source

The current source used to update volatility data

=cut

has volatility_source => (
    is         => 'ro',
    isa        => 'bom_volatility_source',
    lazy_build => 1,
);

sub _build_volatility_source {
    return BOM::Platform::Runtime->instance->app_config->quants->market_data->volatility_source;
}

has _logger => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__logger {
    return get_logger;
}

=head1 METHODS

=head2 grab_files

Grab relevant master response files from the relevant server.

=cut

sub grab_files {
    my ($self, $arg_ref) = @_;

    my $file_type = lc $arg_ref->{file_type};
    my $dir;

    if ($file_type !~ /^(?:interest_rate|vols|ohlc|forward_rates|corporate_actions)$/) {
        die "Invalid file_type [$file_type] passed";
    }

    my @list;

    #COMMENTED FOR NOW BECAUSE DES-386 IS GOING NUTS

    #DO NOT USE: JYSoptionsMACRO.csv
    # Define the file to be grab in f_cron_primary
    if ($file_type eq 'interest_rate') {
        push @list, 'interest_rate.csv';
    } elsif ($file_type eq 'vols') {
        my $type;
        if ($self->volatility_source eq 'OVDV') {
            $type = 'OVDV';
        } else {
            $type = 'points';
            push @list, 'quantovol.csv';
        }

        for (0 .. 23) {
            push @list, 'fxvol' . sprintf('%02d', $_) . '45_' . $type . '.csv';
        }
    } elsif ($file_type eq 'ohlc') {
        my $request_files = BOM::MarketData::Parser::Bloomberg::RequestFiles->new->_ohlc_request_files;
        foreach my $request (@{$request_files}) {
            if ($request =~ /^(\w+).req/) { push @list, $1 . '.csv'; }
        }
    } elsif ($file_type eq 'forward_rates') {
        push @list, 'forward_rates.csv';
    } elsif ($file_type eq 'corporate_actions') {
        push @list, 'corporate.csv';
    }

    my @successfiles;

    my $sftp = $self->login;
    my $now  = Date::Utility->new;

    $self->_logger->debug('Logged into ' . $self->sftp_server_ip);
    FILE:
    foreach my $file (@list) {
        # check file modification fime
        my $file_stat = $sftp->stat("$file.enc");
        if (not $file_stat) { next; }
        my $mdtm     = $file_stat->mtime;
        my $mod_time = Date::Utility->new($mdtm);
        my $mtime    = $mod_time->datetime . ' (' . ($now->epoch - $mod_time->epoch) . ' seconds ago)';
        if ($file_stat) {
            # warn if modification time too old
            if (    not $now->is_a_weekend
                and $now->day_of_week != 1
                and $now->epoch - $mdtm > 86400 * 1.5
                and $file !~ /(interest_rate|corporate_actions)/)
            {
                $self->_logger->error("Bloomberg data license file[$file] is too old! mtime[$mtime]");
            }

            #for FX vols, we run every 10 minutes , but we make a torelance of 20 minutes instead, so only process the latest one
            next FILE if ($now->epoch - $mdtm > 1200 and $file =~ /fx/);

            next FILE if ($now->epoch - $mdtm > 5400 and $file =~ /ohlc/);

            my $size = $file_stat->size;
            my $when = Date::Utility->new;
            if ($size == 0) {
                $self->_logger->error("Zero size/not exists $file.enc");
            } else {
                $self->_logger->debug("$file.enc SIZE=$size MTIME=$mtime");
            }
        } else {
            die "no file stat for ($file)";
        }

        $sftp->get("$file.enc", "/tmp/$file.enc");

        if ($sftp->error) {
            $self->_logger->error("Failed to get the $file.enc file:" . $sftp->error);
        } else {
            unlink "/tmp/$file";

            # check file is not empty
            if (-s "/tmp/$file.enc" < 10) {
                $self->_logger->error("$file.enc file size seems too small.");
            } else {
                my $response_file;
                my $data_dir = path($self->data_dir);
                if ($file_type eq 'vols') {
                    my $hhmmss = $mod_time->time_hhmmss;
                    $hhmmss =~ s/://g;

                    if ($file =~ /OVDV/) {
                        $response_file = 'fx' . $hhmmss . "_OVDV.csv";
                    } elsif ($file =~ /points/) {
                        $response_file = 'fx' . $hhmmss . "_vol_points.csv";
                    } elsif ($file =~ /quantovol/) {
                        next;
                    } else {
                        croak 'Invalid file from BBDL[' . $file . '] ';
                    }

                    $dir = $data_dir->child($self->volatility_source, $mod_time->date_yyyymmdd);
                    $dir->mkpath unless $dir->is_dir;
                } else {
                    $response_file = $file;
                    $dir           = $data_dir;
                }

                if ($self->des_decrypt("/tmp/$file.enc", "$dir/$response_file")) {
                    push @successfiles, "/$dir/$response_file";
                    if ($file =~ /points/) {
                        $self->des_decrypt("/tmp/quantovol.csv.enc", "$dir/quantovol.csv");
                        push @successfiles, "/$dir/quantovol.csv";
                    }
                } else {
                    $self->_logger->error("$file.enc could not decrypt.");
                }
            }
        }
    }

    $sftp->disconnect;

    return @successfiles;
}

=head2 login

Logs into the BBDL FTP service. Returns the logged in instance of Net::SFTP::Foreign.

=cut

sub login {
    my $self = shift;

    my $sftp = Net::SFTP::Foreign->new(
        $self->sftp_server_ip,
        timeout  => 45,
        user     => 'dl623471',
        password => 'rEGENTmK',
        port     => '30206',
        more     => [-o => 'StrictHostKeyChecking no'],
    );
    $sftp->die_on_error("Unable to establish SFTP connection to bloomberg");

    $sftp->setcwd('/')
        or die "Cannot change current working directory " . $sftp->error;

    return $sftp;
}

=head2 des_decrypt

Decrypt a file downloaded from BBDL. Takes "from" and "to" filenames as args:

  $bbdl->des_decrypt('/tmp/myfile.csv.enc', '/tmp/myfile.csv');

=cut

sub des_decrypt {
    my ($self, $fromfile, $tofile) = @_;

    return if not -e $fromfile;
    #des-i386 -D -u -k "iWC9:6A1" file.enc file
    # See setupscripts/bloomberg-des for a description of this binary
    # and why we are forced to package it ourselves.
    system("nice -n 19 /usr/bin/des-standalone -D -u -k iWC9:6A1 $fromfile $tofile");

    if ($? != 0) {
        croak 'Failed to decrypt file from ' . $fromfile . ' to ' . $tofile . '. Reason: ' . $!;
    }

    my $fs = (-s $tofile) || 0;
    if ($fs > 20000000) {
        unlink $tofile;
        $self->_logger->error("des-standalone produced output file[$tofile] of size[$fs]");
        return 0;
    } elsif (!-f $tofile) {
        $self->_logger->error("des-standalone failed, $tofile not created: $!");
        return 0;
    }

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
