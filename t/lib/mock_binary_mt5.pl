# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use JSON::MaybeXS;

use constant {
    MT_RET_OK => 0,
};

# Mocked account details
# This hash shared between two files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '__MOCK__',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\something',
    country  => 'Malta',
    balance  => '1234.56',
);

my $json = JSON::MaybeXS->new;

my $cmd = shift @ARGV;
my $input = $json->decode(do { local $/; <STDIN> });

if(my $code = main->can("cmd_$cmd")) {
    my $output = $code->($input);
    print $json->encode($output) . "\n";
    exit 0;
}
else {
    print STDERR "Unrecognised command $cmd\n";
    exit 1;
}

sub cmd_UserAdd {
    my ($input) = @_;

    $input->{email} eq $DETAILS{email} or
        die "TODO: mock UserAdd on unknown email\n";

    $input->{country} eq $DETAILS{country} or
        die "UserAdd with unexpected country=$input->{country}\n";
    $input->{mainPassword} eq $DETAILS{password} or
        die "UserAdd with unexpected mainPassword=$input->{mainPassword}\n";

    return {
        ret_code => MT_RET_OK,
        login    => $DETAILS{login},
    };
}

sub cmd_UserDepositChange {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login} or
        die "TODO: mock UserDepositChange on unknown login\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserGet {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login} or
        die "TODO: mock UserGet on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            login   => $DETAILS{login},
            email   => $DETAILS{email},
            name    => $DETAILS{name},
            group   => $DETAILS{group},
            country => $DETAILS{country},
            balance => $DETAILS{balance},
        },
    };
}

sub cmd_UserUpdate {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login} or
        die "TODO: mock UserUpdate on unknown login\n";

    $input->{name} eq "Test2" or
        die "UserUpdate with unexpected name$input->{name}\n";
    $input->{country} eq $DETAILS{country} or
        die "UserUpdate with unexpected country=$input->{country}\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            login   => $DETAILS{login},
            email   => $DETAILS{email},
            name    => "Test2",
            country => $DETAILS{country},
            balance => $DETAILS{balance},
        },
    };
}

sub cmd_UserPasswordChange {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login} or
        die "TODO: mock UserUpdate on unknown login\n";

    $input->{new_password} eq "Ijkl6789" or
        die "UserPasswordChange with unexpected new_password=$input->{new_password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserPasswordCheck {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login} or
        die "TODO: mock UserUpdate on unknown login\n";

    $input->{password} eq $DETAILS{password} or
        die "UserPasswordCheck with unexpected password=$input->{password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}
