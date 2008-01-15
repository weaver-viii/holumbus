# Making all
#
# Building the library and generating documentation is done by cabal,
# only the tests and the examples will be built using make.

TEST_BASE			= test
EXAMPLES_BASE	= examples

all : configure build alltests allexamples doc
	
configure :
	@runhaskell Setup.hs configure

doc	: configure
	@runhaskell Setup.hs haddock --hyperlink-source --hscolour-css=hscolour.css

build	: configure
	@runhaskell Setup.hs build

install :
	@runhaskell Setup.hs install

prof	:
	@runhaskell Setup.hs configure -p
	@runhaskell Setup.hs build

alltests :
	$(MAKE) -C $(TEST_BASE) all

allexamples :
	$(MAKE) -C $(EXAMPLES_BASE) all

wc :
	@wc -l `find ./$(EXAMPLES_BASE) ./source ./$(TEST_BASE) -wholename './_darcs/*' -prune -o -name "*.hs" -print`   

clean :
	@runhaskell Setup.hs clean
	$(MAKE) -C $(TEST_BASE) clean
	$(MAKE) -C $(EXAMPLES_BASE) clean
				 
