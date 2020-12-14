# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t and t/BOM/RPC/05_accounts.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use List::Util qw(pairgrep first);
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::BOM::RPC::Accounts;

use constant {
    MT_RET_OK                   => 0,
    MT_RET_USR_INVALID_PASSWORD => 3006,
};

use constant SIMPLE_PASSWORD => 'abc123';

# Mocked account details

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

my %GROUP_DETAILS = (
    currency => 'USD',
    group    => 'real01\synthetic\svg_std_usd',
    leverage => 300,
    company  => 'Deriv (SVG) LLC'
);

my $json = JSON::MaybeXS->new;

my $cmd   = shift @ARGV;
my $input = $json->decode(
    do { local $/; <STDIN> }
);

if (my $code = main->can("cmd_$cmd")) {
    my $output = $code->($input);
    print $json->encode($output) . "\n";
    exit 0;
} else {
    print STDERR "Unrecognised command $cmd\n";
    exit 1;
}

sub cmd_UserAdd {
    my ($input) = @_;

    exists $ACCOUNTS{$input->{group}} or die "UserAdd with unexpected group=$input->{group}\n";

    return {
        ret_code => MT_RET_USR_INVALID_PASSWORD,
        error    => 'password formatting is wrong',
    } if $input->{mainPassword} eq SIMPLE_PASSWORD;

    $input->{mainPassword} eq $DETAILS{password}->{main}
        or die "UserAdd with unexpected mainPassword=$input->{mainPassword}\n";

    #disable check since password is generated auto when it is not provided
    # $input->{investPassword} eq $DETAILS{password}->{investor}
    #    or die "UserAdd with unexpected investorPassword=$input->{investPassword}\n";

    return {
        ret_code => MT_RET_OK,
        login    => $ACCOUNTS{$input->{group}},
    };
}

sub cmd_UserDepositChange {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock UserDepositChange on unknown login\n";

    # This command is invoked for both deposits and withdrawals, the sign of
    # the amount indicating which
    $input->{new_deposit} == 10000          # initial balance
        or $input->{new_deposit} == 180     # deposit
        or $input->{new_deposit} == -150    # withdrawal
        or die "TODO: mock UserDepositChange on unknown new_deposit amount\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserGet {
    my ($input) = @_;

    my $group = get_account_group($input->{login})
        or die "TODO: mock UserGet on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            (pairgrep { $a ne 'password' } %DETAILS),
            group => $group,
            login => $input->{login}}};
}

sub cmd_GroupGet {
    my ($input) = @_;

    return {
        ret_code => MT_RET_OK,
        group    => {
            %GROUP_DETAILS,
            group => $input->{group},
        },
    };
}

sub cmd_UserUpdate {
    my ($input) = @_;

    my $group = get_account_group($input->{login}) or die "TODO: mock UserUpdate on unknown login\n";

    $input->{name} eq "Test2"
        or die "UserUpdate with unexpected name$input->{name}\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            (pairgrep { $a ne "password" } %DETAILS),
            name  => "Test2",
            group => $group
        },
    };
}

sub cmd_UserPasswordChange {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{type} eq 'main' || $input->{type} eq 'investor'
        or die "UserPasswordChange with unexpected password_type\n";

    $input->{new_password} eq "Ijkl6789" || $input->{new_password} eq "Abcd1234"
        or die "UserPasswordChange with unexpected new_password=$input->{new_password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserPasswordCheck {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{password} eq $DETAILS{password}->{$input->{type}}
        or return {
        ret_code => MT_RET_USR_INVALID_PASSWORD,
        error    => 'Invalid account password',
        };

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_PositionGetTotal {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock PositionGetTotal on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        total    => 0,
    };
}

sub get_account_group {
    my $login = shift;
    return first { $ACCOUNTS{$_} eq $login } keys %ACCOUNTS;
}
