v3:
	prove -v --timer -I./lib -I./t -r t/BOM/WebsocketAPI/v3

structure:
	prove --timer -I./lib  -I./t t/BOM/*.t

leaktest:
	prove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/leak/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
