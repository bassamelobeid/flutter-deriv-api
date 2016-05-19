v3_1:
	bash -c 'prove --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3/{0,1,2,3,4}*'

v3_2:
	bash -c 'prove --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3/{5,6,7,8,9}*'

structure:
	prove --timer -I./lib  -I./t t/BOM/*.t

leaktest:
	prove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/leak/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
