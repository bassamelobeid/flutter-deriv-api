# BOM-User

## NAME

BOM::User - main class, containing methods to manage user object.
BOM::User::Client - main class, containing methods to manage clients and various client related statuses, promotions, limits, payments etc. 

## SYNOPSIS

```
# A user represents a person, so the first step is to create one of those
# in the database.
my $hash_pwd = BOM::Platform::Password::hashpw("Passw0rd");
my %new_user_details = (
    email           => 'jsmith@somedomain.com',
    # Remaining details are optional
    password        => $hash_pwd,
    residence       => 'br',
    last_name       => 'Smith',
    first_name      => 'John',
    salutation      => 'Mr',
    address_line_1  => 'Some address line',
    address_city    => 'City',
    phone           => '+60123456789',
    secret_question => "Mother's maiden name",
    secret_answer   => 'Johnson',
);
my $u = BOM::User->create(\%new_user_details);

# Once you have a user, you'll need one or more clients to be able to log in or trade
my %new_client_details = (
    landing_company => 'svg',
);
my $c = $u->create_client(\%new_client_details);
print $c->loginid; # should give something like CR1234

# set default account currency
$c->set_default_account('USD');

# get client from db
$c = BOM::User::Client->new({loginid => 'CR1234'});

# get client's status and various info
my $status = $c->status->get;
my $email  = $u->email;

# produce some payments
$c->validate_payment({
    amount   => 100,
    currency => 'GBP'
});
$c->payment_account_transfer({
    toClient => $some_client_id,
    currensy => 'USD'
});

$user->add_loginid({loginid => $c->loginid});
$user->save;

my @clienst = $user->clients;

```
#### DESCRIPTION

This repo contains objects to abstract company's business logic related to clients management and client's payments management

* BOM::User::Client::PaymentAgent - class to represent any client as a separate payment agent.
* BOM::User::Client::Desk, which is a wrapper around WWW::Desk - Desk.com API.
* BOM::User::Client::PaymentAgent, which include client payment agent system.
* BOM::User::Client::Payments, which include staff about payment

Note about terminology:

* 'User' means a customer identified by his email address. This is how customers log into the website.
* 'Client' means a loginID (CR12345 etc..) - a User can have multiple Clients.
* 'BOM::User::Client' means a currency account, e.g. CR12345:USD. In the past we used to allow a Client (loginID) to have more than one currency, but now we impose only one currency per Client.

#### TEST
    # run all test scripts
    make test
    # run one script
    prove t/BOM/user.t
    # run one script with perl
    perl -MBOM::Test t/BOM/user.t

#### DEPENDENCIES

* cpan
* bom-postgres
* bom-postgres-clientdb
* bom-postgres-collectordb
* bom-postgres-userdb
* bom-test

