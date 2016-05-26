CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

default:
	@echo "You must specify target. The following targets available:"
	@echo "  tidy         - Run perltidy"

tidy:
	find . -name '*.p?.bak' -delete
	find . -name '*.p[lm]' -o -name '*.cgi' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

unit_test:
	prove --timer -l -I./t -r t/

data_js:
	rm -f statics/javascript/data/*
	if [ ! -d "statics/javascript/data" ]; then mkdir -p statics/javascript/data; fi;
	perl -I ./lib -I ./bin -MGenerateStaticData -e "GenerateStaticData->from('statics/javascript/')->generate_data_files()"
