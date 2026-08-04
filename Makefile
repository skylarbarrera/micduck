SWIFTC ?= swiftc
FLAGS  ?= -O

.PHONY: all test probe negtest install launchagent uninstall clean

all: micduck

micduck: micduck.swift
	$(SWIFTC) $(FLAGS) -o $@ $<

micprobe: micprobe.swift
	$(SWIFTC) $(FLAGS) -o $@ $<

negtest: negtest.swift
	$(SWIFTC) $(FLAGS) -o $@ $<

# Ducks and restores once, asserts the volume came back.
test: micduck
	./micduck --selftest

# Logs mic transitions on every input device. Ctrl-C to stop.
probe: micprobe
	./micprobe

# Opens the mic with no keypress — volume should not move.
negtest-run: negtest
	./negtest

install:
	./install.sh

launchagent:
	./install.sh --launchagent

uninstall:
	./install.sh --uninstall

clean:
	rm -rf micduck micprobe negtest *.dSYM
