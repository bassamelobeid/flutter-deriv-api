# perl-Client-Account

#### NAME
BOM::User - Class representing a company's user object.
Client::Account - Class representing a company's client related business logic

#### SYNOPSYS
```
my %new_client_details = (
    broker_code     => 'CR',
    residence       => 'br',
    client_password => 'x',
    last_name       => 'Smith',
    first_name      => 'John',
    email           => 'jsmith@somedomain.com',
    salutation      => 'Mr',
    address_line_1  => 'Some address line',
    address_city    => 'City',
    phone           => '+60123456789',
    secret_question => "Mother's maiden name",
    secret_answer   => 'Johnson',
);

# create new client
my $c = BOM::User::Client->register_and_return_new_client(\%new_client_details);
# set default account currency
$c->set_default_account('USD');

# get client from db
$c = BOM::User::Client->new({loginid => 'CLLOGIN'});

# get client's status and various info
my $status = $c->get_status;
my $email  = $c->email;

# produce some payments
$c->validate_payment({
    amount   => 100,
    currency => 'GBP'
});
$c->payment_account_transfer({
    toClient => $some_client_id,
    currensy => 'USD'
});

my $hash_pwd = BOM::Platform::Password::hashpw("Passw0rd");
my $user     = BOM::User->create(
    email    => $email,
    password => $hash_pwd;
);

$user->add_loginid({loginid => $c->loginid});
$user->save;

my @clienst = $user->clients;

```
#### DESCRIPTION

This repo contains objects to abstract company's business logic related to clients management and client's payments management

* BOM::User - main class, containing methods to manage user object.
* BOM::User::Client - main class, containing methods to manage clients and various client related statuses, promotions, limits, payments etc. 
* BOM::User::Client::PaymentAgent - class to represent any client as a separate payment agent.
* BOM::User::Client::Desk, which is a wrapper around WWW::Desk - Desk.com API.

*This module contains dependencies to be removed in upcoming versions

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
