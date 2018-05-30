# bom-websocket-tests

##To run Websocket API tests on a QA devbox
- cd `/home/git/regentmarkets/bom-websocket-tests`
- prove --rc `/home/git/regentmarkets/binary-websocket-api/.proverc` -vl `v3/[testfile].t`

Note: This will include dependencies from `.proverc` file in the `binary-websocket-api`

---

##JSON Schema Testing

The JSON Schema testing files are all located in `v3/schema_suite/`. In these files we use a number of functions listed below (with their description, usage and examples).

---
###start

You will encounter this function which initializes the entire test module. Certain following functions can only be called through this module (i.e. `get_token` and `get_stashed`). 

```
my $suite = start(
    title             => "example.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);
```

You want to save the result of the function in a variable ($suite) to be able to call `get_token` and `get_stashed` later on. (e.g. `$suite->get_token`).

###get_token

This function retrieves the latest token generated for a certain email. This includes `account_opening` verification code, `payment_withdraw` token and others.
Note that you will need to call `test_sendrecv_params` with the `verify_email` parameters along with the token type you wish to receive.

```
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test@binary.com', 'account_opening';
$suite->get_token('test@binary.com');
```

###get_stashed

All responses generated are stored for each successful api call made. These responses are all accessible with the use of this fuction. The responses are stored in an object with the name of the call made. 

```
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
$suite->get_stashed('proposal/proposal/id');
```
```
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json', 'test';
$suite->get_stashed('api_token/api_token/tokens/0/token');
```

###free_gift

Use this to give an account a free gift of a specified amount in a specified currency. If no currency is provided, USD is chosen by default. If no amount is specified, 10000 is chosen by default.
```
$suite->free_gift("CR90000001", 'GBP', '12345');
```
However, in these test cases, it is highly recommended to use the stored login id from a previous call that was made.
```
$suite->free_gift($suite->get_stashed('new_account_real/new_account_real/client_id'), 'GBP', '12345');
```

###