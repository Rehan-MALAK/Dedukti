# Current version number of Dedukti.
VERSION = master

# Compile with "make Q=" to display the commands that are run.
Q = @

all: kernel parser commands META

#### Compilation of the kernel library #######################################

KERNEL_MLI := $(wildcard kernel/*.mli)
KERNEL_ML  := $(KERNEL_MLI:.mli=.ml)

.PHONY: kernel
kernel: _build/kernel/kernel.cma _build/kernel/kernel.cmxa

kernel/version.ml: GNUmakefile
	@echo "[GEN] $@ ($(VERSION))"
	$(Q)echo 'let version = "$(VERSION)"' > $@

_build/kernel/kernel.cma: $(KERNEL_MLI) $(KERNEL_ML)
	@echo "[BYT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind kernel/kernel.cma

_build/kernel/kernel.cmxa: $(KERNEL_MLI) $(KERNEL_ML)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind kernel/kernel.cmxa

#### Compilation of the parser library #######################################

PARSER_MLI := $(wildcard parser/*.mli)
PARSER_ML  := $(PARSER_MLI:.mli=.ml)
PARSER_GEN := parser/parser.mly parser/lexer.mll

.PHONY: parser
parser: kernel _build/parser/parser.cma _build/parser/parser.cmxa

_build/parser/parser.cma: $(PARSER_MLI) $(PARSER_ML) $(PARSER_GEN)
	@echo "[BYT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind parser/parser.cma

_build/parser/parser.cmxa: $(PARSER_MLI) $(PARSER_ML) $(PARSER_GEN)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind parser/parser.cmxa

#### Compilation of the dedukti suite ########################################

.PHONY: commands
commands: dkcheck.native dkdep.native dkindent.native dktop.native

dkcheck.native: $(wildcard dkcheck/*.ml) $(wildcard dkcheck/*.mli)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind dkcheck/dkcheck.native

dkdep.native: $(wildcard dkdep/*.ml) $(wildcard dkdep/*.mli)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind dkdep/dkdep.native

dkindent.native: $(wildcard dkindent/*.ml) $(wildcard dkindent/*.mli)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind dkindent/dkindent.native

dktop.native: $(wildcard dktop/*.ml) $(wildcard dktop/*.mli)
	@echo "[OPT] $@"
	$(Q)ocamlbuild -quiet -use-ocamlfind dktop/dktop.native

#### Generation of the META file #############################################

META: GNUmakefile
	@echo "[GEN] $@"
	@echo 'name = "dedukti"'                                             > META
	@echo 'version = "$(VERSION)"'                                      >> META
	@echo 'description = "Dedukti library - λΠ-calculus modulo theory"' >> META
	@echo 'requires = "unix"'                                           >> META
	@echo 'archive(byte) = "dedukti.cma"'                               >> META
	@echo 'archive(native) = "dedukti.cmxa"'                            >> META
	@echo                                                               >> META
	@echo 'package "parser" ('                                          >> META
	@echo '  version = "$(VERSION)"'                                    >> META
	@echo '  description = "Dedukti parser"'                            >> META
	@echo '  requires = "unix, dedukti"'                                >> META
	@echo '  archive(byte) = "parser.cma"'                              >> META
	@echo '  archive(native) = "parser.cmxa"'                           >> META
	@echo ')'                                                           >> META

#### Installation targets ####################################################

BINDIR = $(dir $(shell which ocaml))

.PHONY: uninstall
uninstall:
	@ocamlfind remove dedukti
	@rm -f $(BINDIR)/dkcheck
	@rm -f $(BINDIR)/dkdep
	@rm -f $(BINDIR)/dkindent
	@rm -f $(BINDIR)/dktop

.PHONY: install
install: uninstall all
	@ocamlfind install dedukti META \
		$(wildcard _build/kernel/*.mli) $(wildcard _build/kernel/*.cmi) \
		$(wildcard _build/kernel/*.cmo) $(wildcard _build/kernel/*.cmx) \
		$(wildcard _build/kernel/*.o) _build/kernel/kernel.cma \
		_build/kernel/kernel.cmxa _build/kernel/kernel.a \
		$(wildcard _build/parser/*.mli) $(wildcard _build/parser/*.cmi) \
		$(wildcard _build/parser/*.cmo) $(wildcard _build/parser/*.cmx) \
		$(wildcard _build/parser/*.o) _build/parser/parser.cma \
		_build/parser/parser.cmxa _build/parser/parser.a
	install -m 755 -d $(BINDIR)
	install -m 755 -p dkcheck.native  $(BINDIR)/dkcheck
	install -m 755 -p dkdep.native    $(BINDIR)/dkdep
	install -m 755 -p dkindent.native $(BINDIR)/dkindent
	install -m 755 -p dktop.native    $(BINDIR)/dktop

#### Cleaning targets ########################################################

clean:
	$(Q)ocamlbuild -quiet -clean

distclean: clean
	$(Q)find -name "*~" -exec rm {} \;
	$(Q)rm -f kernel/version.ml
	$(Q)rm -f META
