# Thin wrapper around install.sh. Run `make install`.
#
# filter.bpf (the seccomp denylist consumed by `bwrap --seccomp`) is committed,
# so plain `make install` needs no toolchain. Regenerate it with `make seccomp`
# after editing gen-seccomp.c — that step needs a C compiler and libseccomp.

CC ?= cc
CFLAGS ?= -O2 -Wall

.PHONY: install uninstall seccomp clean

install:
	@./install.sh

# Rebuild the committed seccomp blob from source.
seccomp: filter.bpf

filter.bpf: gen-seccomp.c
	$(CC) $(CFLAGS) -o gen-seccomp gen-seccomp.c -lseccomp
	./gen-seccomp filter.bpf

clean:
	@rm -f gen-seccomp

uninstall:
	@for d in "$$HOME/.local/bin" "$$HOME/bin"; do \
	    rm -f "$$d/aye-buddy" "$$d/ll-helper" "$$d/filter.bpf"; \
	done
	@rm -f "$$HOME/.config/fish/functions/claude.fish"
	@echo "note: for bash/zsh, remove the 'aye-buddy: claude shell function' block from your rc file manually"
