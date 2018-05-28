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

All responses generated are stored for each api call made. These responses are all accessible with the use of this fuction. When a successful call is made, 