# Thin wrapper around install.sh. Run `make install`.
#
# The seccomp denylists consumed by `bwrap --seccomp` are committed, so plain
# `make install` needs no toolchain. filter.bpf is the default; filter-nested.bpf
# is the relaxed variant aye-buddy uses under --allow-bwrap (mount/namespace
# syscalls re-allowed so a nested bwrap can run). Regenerate both with
# `make seccomp` after editing gen-seccomp.c — that step needs cc and libseccomp.

CC ?= cc
CFLAGS ?= -O2 -Wall

.PHONY: install uninstall seccomp clean test

install:
	@./install.sh

# Black-box tests for aye-buddy's option parsing (core Perl only, no CPAN deps).
# Run with prove; fall back to prove in Perl's scriptdir when it's off PATH
# (e.g. Arch/Manjaro keep it in /usr/bin/core_perl).
PROVE ?= prove
test:
	@P=$$(command -v $(PROVE) || echo "$$(perl -MConfig -e 'print $$Config{scriptdir}')/prove"); \
	"$$P" -lr t/

# Rebuild the committed seccomp blobs from source.
seccomp: filter.bpf filter-nested.bpf

filter.bpf filter-nested.bpf: gen-seccomp.c
	$(CC) $(CFLAGS) -o gen-seccomp gen-seccomp.c -lseccomp
	./gen-seccomp filter.bpf
	./gen-seccomp --allow-nested-bwrap filter-nested.bpf

clean:
	@rm -f gen-seccomp

uninstall:
	@for d in "$$HOME/.local/bin" "$$HOME/bin"; do \
	    rm -f "$$d/aye-buddy" "$$d/ll-helper" "$$d/aye-proxy" "$$d/aye-net-helper" "$$d/AyeSeccomp.pm" "$$d/filter.bpf" "$$d/filter-nested.bpf"; \
	done
	@rm -f "$$HOME/.config/fish/functions/claude.fish"
	@echo "note: for bash/zsh, remove the 'aye-buddy: claude shell function' block from your rc file manually"
