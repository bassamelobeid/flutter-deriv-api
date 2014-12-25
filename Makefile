v3_1:
	bash -c 'prove --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3/{0,1,2,4}*'

v3_2:
	bash -c 'prove --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3/{5,6,7}*'

v3_3:
	bash -c 'prove --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3/{8,9}*'

json_schema:
	bash -c 'date -s \'2016-08-09 12:00:00\'; prove --timer -I./lib -I./t t/BOM/WebsocketAPI/v3/schema_suite/suite.t'

structure:
	prove --timer -I./lib  -I./t t/BOM/*.t

leaktest:
	prove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/leak/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
