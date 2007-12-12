# Making all
#
# Building the library and generating documentation is done by cabal,
# only the tests and the examples will be built using make.

TEST_BASE			= test
EXAMPLES_BASE	= examples

all : lib alltests allexamples doc
	
configure : .setup-config

doc	: configure
	@runhaskell Setup.hs haddock

lib	: configure
	@runhaskell Setup.hs build

install : lib
	@runhaskell Setup.hs install

.setup-config :
	@runhaskell Setup.hs configure

alltests :
	$(MAKE) -C $(TEST_BASE) all

allexamples :
	$(MAKE) -C $(EXAMPLES_BASE) all

clean :
	@runhaskell Setup.hs clean
	$(MAKE) -C $(TEST_BASE) clean
	$(MAKE) -C $(EXAMPLES_BASE) clean
				 