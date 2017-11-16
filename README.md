# bom-websocket-tests

Websocket API tests

To run Websocket API tests on QA devbox, please do:
- cd `/home/git/regentmarkets/binary-websocket-api`
- prove -vl `../bom-websocket-tests/v3/[testfile].t`

It will include dependencies from `.proverc` file in the `binary-websocket-api`.
