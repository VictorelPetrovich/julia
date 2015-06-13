JULIAHOME = $(abspath .)
include $(JULIAHOME)/Make.inc

# TODO: Code bundled with Julia should be installed into a versioned directory,
# prefix/share/julia/VERSDIR, so that in the future one can have multiple
# major versions of Julia installed concurrently. Third-party code that
# is not controlled by Pkg should be installed into
# prefix/share/julia/site/VERSDIR (not prefix/share/julia/VERSDIR/site ...
# so that prefix/share/julia/VERSDIR can be overwritten without touching
# third-party code).
VERSDIR = v`cut -d. -f1-2 < VERSION`
INSTALL_F = contrib/install.sh 644
INSTALL_M = contrib/install.sh 755

#file name of make binary-dist result
ifeq ($(JULIA_BINARYDIST_TARNAME),)
	JULIA_BINARYDIST_TARNAME = julia-$(JULIA_COMMIT)-$(OS)-$(ARCH)
endif

all: default
default: release

# sort is used to remove potential duplicates
DIRS = $(sort $(build_bindir) $(build_libdir) $(build_private_libdir) $(build_libexecdir) $(build_sysconfdir)/julia $(build_datarootdir)/julia $(build_datarootdir)/man/man1)

$(foreach dir,$(DIRS),$(eval $(call dir_target,$(dir))))
$(foreach link,base test doc examples,$(eval $(call symlink_target,$(link),$(build_datarootdir)/julia)))

git-submodules:
ifneq ($(NO_GIT), 1)
	@-git submodule update --init
else
       $(warn "Submodules could not be updated because git is unavailable")
endif

debug release: | $(DIRS) $(build_datarootdir)/julia/base $(build_datarootdir)/julia/test $(build_datarootdir)/julia/doc $(build_datarootdir)/julia/examples $(build_sysconfdir)/julia/juliarc.jl
	@$(MAKE) $(QUIET_MAKE) julia-$@
	@export private_libdir=$(private_libdir) && \
	$(MAKE) $(QUIET_MAKE) LD_LIBRARY_PATH=$(build_libdir):$(LD_LIBRARY_PATH) JULIA_EXECUTABLE="$(JULIA_EXECUTABLE_$@)" $(build_private_libdir)/sys.$(SHLIB_EXT)

release-candidate: release test
	@#Check documentation
	@$(JULIA_EXECUTABLE) doc/NEWS-update.jl #Add missing cross-references to NEWS.md
	@$(MAKE) -C doc unicode #Rebuild Unicode table if necessary
	@$(JULIA_EXECUTABLE) doc/DocCheck.jl > doc/UNDOCUMENTED.rst 2>&1 #Check for undocumented items
	@if [ -z "$(cat doc/UNDOCUMENTED.rst)" ]; then \
		rm doc/UNDOCUMENTED.rst; \
	else \
		echo "Undocumented functions found in doc/UNDOCUMENTED.rst; document them, then retry"; \
		exit 1; \
	fi
	@$(MAKE) -C doc html  SPHINXOPTS="-n" #Rebuild Julia HTML docs pedantically
	@$(MAKE) -C doc latex SPHINXOPTS="-n" #Rebuild Julia PDF docs pedantically
	@$(MAKE) -C doc doctest #Run Julia doctests
	@$(MAKE) -C doc linkcheck #Check all links
	@$(MAKE) -C doc helpdb.jl #Rebuild Julia online documentation for help(), apropos(), etc...

	@# Check to see if the above make invocations changed anything important
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "Git repository dirty; Verify and commit changes to the repository, then retry"; \
		exit 1; \
	fi

	@#Check that benchmarks work
	@$(MAKE) -C test/perf
	@#Check that netload tests work
	@#for test in test/netload/*.jl; do julia $$test; if [ $$? -ne 0 ]; then exit 1; fi; done
	@echo
	@echo To complete the release candidate checklist:
	@echo

	@echo 1. Remove deprecations in base/deprecated.jl
	@echo 2. Bump VERSION
	@echo 3. Create tag, push to github "\(git tag v\`cat VERSION\` && git push --tags\)"		#"` # These comments deal with incompetent syntax highlighting rules
	@echo 4. Clean out old .tar.gz files living in deps/, "\`git clean -fdx\`" seems to work	#"`
	@echo 5. Replace github release tarball with tarball created from make full-source-dist
	@echo 6. Follow packaging instructions in DISTRIBUTING.md to create binary packages for all platforms
	@echo 7. Upload to AWS, update http://julialang.org/downloads and http://status.julialang.org/stable links
	@echo 8. Update checksums on AWS for tarball and packaged binaries
	@echo 9. Announce on mailing lists
	@echo

julia-debug-symlink:
	@ln -sf $(build_bindir)/julia-debug julia

julia-release-symlink:
	@ln -sf $(build_bindir)/julia julia

julia-debug julia-release: git-submodules
	@$(MAKE) $(QUIET_MAKE) -C deps
	@$(MAKE) $(QUIET_MAKE) -C src lib$@
	@$(MAKE) $(QUIET_MAKE) -C base
	@$(MAKE) $(QUIET_MAKE) -C ui $@
ifneq ($(OS),WINNT)
ifndef JULIA_VAGRANT_BUILD
	@$(MAKE) $(QUIET_MAKE) $@-symlink
endif
endif

$(build_datarootdir)/julia/helpdb.jl: doc/helpdb.jl | $(build_datarootdir)/julia
	@cp $< $@

$(build_datarootdir)/man/man1/julia.1: doc/man/julia.1 | $(build_datarootdir)/julia
	@mkdir -p $(build_datarootdir)/man/man1
	@cp $< $@

$(build_sysconfdir)/julia/juliarc.jl: etc/juliarc.jl | $(build_sysconfdir)/julia
	@cp $< $@
ifeq ($(OS), WINNT)
	@cat ./contrib/windows/juliarc.jl >> $(build_sysconfdir)/julia/juliarc.jl
$(build_sysconfdir)/julia/juliarc.jl: contrib/windows/juliarc.jl
endif

# use sys.ji if it exists, otherwise run two stages
$(build_private_libdir)/sys%ji: $(build_private_libdir)/sys%o

.SECONDARY: $(build_private_libdir)/sys.o
.SECONDARY: $(build_private_libdir)/sys0.o

$(build_private_libdir)/sys%$(SHLIB_EXT): $(build_private_libdir)/sys%o
	$(CXX) -shared -fPIC -L$(build_private_libdir) -L$(build_libdir) -L$(build_shlibdir) -o $@ $< \
		$$([ $(OS) = Darwin ] && echo -Wl,-undefined,dynamic_lookup || echo -Wl,--unresolved-symbols,ignore-all ) \
		$$([ $(OS) = WINNT ] && echo -ljulia -lssp)
	$(DSYMUTIL) $@

$(build_private_libdir)/sys0.o:
	@$(QUIET_JULIA) cd base && \
	$(call spawn,$(JULIA_EXECUTABLE)) -C $(JULIA_CPU_TARGET) --build $(call cygpath_w,$(build_private_libdir)/sys0) sysimg.jl

$(build_private_libdir)/sys.o: VERSION base/*.jl base/pkg/*.jl base/linalg/*.jl base/sparse/*.jl $(build_datarootdir)/julia/helpdb.jl $(build_datarootdir)/man/man1/julia.1 $(build_private_libdir)/sys0.$(SHLIB_EXT)
	@$(QUIET_JULIA) cd base && \
	$(call spawn,$(JULIA_EXECUTABLE)) -C $(JULIA_CPU_TARGET) --build $(call cygpath_w,$(build_private_libdir)/sys) \
		-J$(call cygpath_w,$(build_private_libdir))/$$([ -e $(build_private_libdir)/sys.ji ] && echo sys.ji || echo sys0.ji) -f sysimg.jl \
		|| (echo "*** This error is usually fixed by running 'make clean'. If the error persists, try 'make cleanall'. ***" && false)

run-julia-debug run-julia-release: run-julia-%:
	$(MAKE) $(QUIET_MAKE) run-julia JULIA_EXECUTABLE="$(JULIA_EXECUTABLE_$*)"
run-julia:
	@$(call spawn,$(JULIA_EXECUTABLE))
run:
	@$(call spawn,$(cmd))

$(build_bindir)/stringreplace: contrib/stringreplace.c | $(build_bindir)
	@$(call PRINT_CC, $(CC) -o $(build_bindir)/stringreplace contrib/stringreplace.c)


# public libraries, that are installed in $(prefix)/lib
JL_LIBS = julia julia-debug

# private libraries, that are installed in $(prefix)/lib/julia
JL_PRIVATE_LIBS = suitesparse_wrapper grisu Rmath
ifeq ($(USE_SYSTEM_FFTW),0)
JL_PRIVATE_LIBS += fftw3 fftw3f fftw3_threads fftw3f_threads
endif
ifeq ($(USE_SYSTEM_PCRE),0)
JL_PRIVATE_LIBS += pcre
endif
ifeq ($(USE_SYSTEM_OPENLIBM),0)
ifeq ($(USE_SYSTEM_LIBM),0)
JL_PRIVATE_LIBS += openlibm
endif
endif
ifeq ($(USE_SYSTEM_OPENSPECFUN),0)
JL_PRIVATE_LIBS += openspecfun
endif
ifeq ($(USE_SYSTEM_DSFMT),0)
JL_PRIVATE_LIBS += dSFMT
endif
ifeq ($(USE_SYSTEM_BLAS),0)
JL_PRIVATE_LIBS += openblas
else ifeq ($(USE_SYSTEM_LAPACK),0)
JL_PRIVATE_LIBS += lapack
endif
ifeq ($(USE_SYSTEM_GMP),0)
JL_PRIVATE_LIBS += gmp
endif
ifeq ($(USE_SYSTEM_MPFR),0)
JL_PRIVATE_LIBS += mpfr
endif
ifeq ($(USE_SYSTEM_ARPACK),0)
JL_PRIVATE_LIBS += arpack
endif
ifeq ($(USE_SYSTEM_SUITESPARSE),0)
JL_PRIVATE_LIBS += amd camd ccolamd cholmod colamd umfpack spqr
endif
#ifeq ($(USE_SYSTEM_ZLIB),0)
#JL_PRIVATE_LIBS += z
#endif
ifeq ($(OS),Darwin)
ifeq ($(USE_SYSTEM_BLAS),1)
ifeq ($(USE_SYSTEM_LAPACK),0)
JL_PRIVATE_LIBS += gfortblas
endif
endif
endif

ifeq ($(OS),WINNT)
define std_dll
debug release: | $$(build_bindir)/lib$(1).dll
$$(build_bindir)/lib$(1).dll: | $$(build_bindir)
ifeq ($$(BUILD_OS),$$(OS))
	cp $$(call pathsearch,lib$(1).dll,$$(PATH)) $$(build_bindir) ;
else
	cp $$(call wine_pathsearch,lib$(1).dll,$$(STD_LIB_PATH)) $$(build_bindir) ;
endif
JL_LIBS += $(1)
endef
$(eval $(call std_dll,gfortran-3))
$(eval $(call std_dll,quadmath-0))
$(eval $(call std_dll,stdc++-6))
ifeq ($(ARCH),i686)
$(eval $(call std_dll,gcc_s_sjlj-1))
else
$(eval $(call std_dll,gcc_s_seh-1))
endif
$(eval $(call std_dll,ssp-0))
endif

install: $(build_bindir)/stringreplace
	@$(MAKE) $(QUIET_MAKE) release
	@$(MAKE) $(QUIET_MAKE) debug
	@for subdir in $(bindir) $(libexecdir) $(datarootdir)/julia/site/$(VERSDIR) $(datarootdir)/man/man1 $(includedir)/julia $(libdir) $(private_libdir) $(sysconfdir); do \
		mkdir -p $(DESTDIR)$$subdir; \
	done

	$(INSTALL_M) $(build_bindir)/julia* $(DESTDIR)$(bindir)/
ifeq ($(OS),WINNT)
	-$(INSTALL_M) $(build_bindir)/*.dll $(build_bindir)/*.bat $(DESTDIR)$(bindir)/
else
	-cp -a $(build_libexecdir) $(DESTDIR)$(prefix)

	# Copy over .dSYM directories directly
ifeq ($(OS),Darwin)
	-cp -a $(build_libdir)/*.dSYM $(DESTDIR)$(private_libdir)
endif

	for suffix in $(JL_LIBS) ; do \
		for lib in $(build_libdir)/lib$${suffix}*.$(SHLIB_EXT)*; do \
			if [ "$${lib##*.}" != "dSYM" ]; then \
				$(INSTALL_M) $$lib $(DESTDIR)$(private_libdir) ; \
			fi \
		done \
	done
	for suffix in $(JL_PRIVATE_LIBS) ; do \
		for lib in $(build_libdir)/lib$${suffix}*.$(SHLIB_EXT)*; do \
			if [ "$${lib##*.}" != "dSYM" ]; then \
				$(INSTALL_M) $$lib $(DESTDIR)$(private_libdir) ; \
			fi \
		done \
	done
endif

ifeq ($(USE_SYSTEM_LIBUV),0)
ifeq ($(OS),WINNT)
	$(INSTALL_F) $(build_includedir)/tree.h $(DESTDIR)$(includedir)/julia
endif
	$(INSTALL_F) $(build_includedir)/uv* $(DESTDIR)$(includedir)/julia
endif
	$(INSTALL_F) src/julia.h src/options.h src/support/*.h $(DESTDIR)$(includedir)/julia
	# Copy system image
	$(INSTALL_F) $(build_private_libdir)/sys.ji $(DESTDIR)$(private_libdir)
	$(INSTALL_M) $(build_private_libdir)/sys.$(SHLIB_EXT) $(DESTDIR)$(private_libdir)
	# Copy in system image build script
	$(INSTALL_M) contrib/build_sysimg.jl $(DESTDIR)$(datarootdir)/julia/
	# Copy in all .jl sources as well
	cp -R -L $(build_datarootdir)/julia $(DESTDIR)$(datarootdir)/
	# Remove git repository of juliadoc
	-rm -rf $(DESTDIR)$(datarootdir)/julia/doc/juliadoc/.git
	-rm $(DESTDIR)$(datarootdir)/julia/doc/juliadoc/.gitignore
	# Copy in beautiful new man page!
	$(INSTALL_F) $(build_datarootdir)/man/man1/julia.1 $(DESTDIR)$(datarootdir)/man/man1/
	# Copy icon and .desktop file
	mkdir -p $(DESTDIR)$(datarootdir)/icons/hicolor/scalable/apps/
	$(INSTALL_F) contrib/julia.svg $(DESTDIR)$(datarootdir)/icons/hicolor/scalable/apps/
	-touch --no-create $(DESTDIR)$(datarootdir)/icons/hicolor/
	-gtk-update-icon-cache $(DESTDIR)$(datarootdir)/icons/hicolor/
	mkdir -p $(DESTDIR)$(datarootdir)/applications/
	$(INSTALL_F) contrib/julia.desktop $(DESTDIR)$(datarootdir)/applications/
	# Install appdata file
	mkdir -p $(DESTDIR)$(datarootdir)/appdata/
	$(INSTALL_F) contrib/julia.appdata.xml $(DESTDIR)$(datarootdir)/appdata/

	# Update RPATH entries and JL_SYSTEM_IMAGE_PATH if $(private_libdir_rel) != $(build_private_libdir_rel)
ifneq ($(private_libdir_rel),$(build_private_libdir_rel))
ifeq ($(OS), Darwin)
	for julia in $(DESTDIR)$(bindir)/julia* ; do \
		install_name_tool -rpath @executable_path/$(build_private_libdir_rel) @executable_path/$(private_libdir_rel) $$julia; \
		install_name_tool -rpath @executable_path/$(build_libdir_rel) @executable_path/$(libdir_rel) $$julia; \
	done
else ifeq ($(OS), Linux)
	for julia in $(DESTDIR)$(bindir)/julia* ; do \
		patchelf --set-rpath '$$ORIGIN/$(private_libdir_rel):$$ORIGIN/$(libdir_rel)' $$julia; \
	done
endif

	# Overwrite JL_SYSTEM_IMAGE_PATH in julia binaries
	for julia in $(DESTDIR)$(bindir)/julia* ; do \
		$(build_bindir)/stringreplace $$(strings -t x - $$julia | grep "sys.ji$$" | awk '{print $$1;}' ) "$(private_libdir_rel)/sys.ji" 256 $(call cygpath_w,$$julia); \
	done
endif

	mkdir -p $(DESTDIR)$(sysconfdir)
	cp -R $(build_sysconfdir)/julia $(DESTDIR)$(sysconfdir)/

distclean dist-clean:
	rm -fr julia-*.tar.gz julia*.exe julia-*.7z julia-$(JULIA_COMMIT)

binary-dist dist: distclean
ifeq ($(USE_SYSTEM_BLAS),0)
ifneq ($(OPENBLAS_DYNAMIC_ARCH),1)
	@echo OpenBLAS must be rebuilt with OPENBLAS_DYNAMIC_ARCH=1 to use binary-dist target
	@false
endif
endif
ifneq ($(prefix),$(abspath julia-$(JULIA_COMMIT)))
	$(error prefix must not be set for make binary-dist)
endif
ifneq ($(DESTDIR),)
	$(error DESTDIR must not be set for make binary-dist)
endif
	@$(MAKE) install
	cp LICENSE.md $(prefix)
ifneq ($(OS), WINNT)
	-./contrib/fixup-libgfortran.sh $(DESTDIR)$(private_libdir)
endif
ifeq ($(OS), Linux)
	-./contrib/fixup-libstdc++.sh $(DESTDIR)$(private_libdir)
endif
	# Copy in juliarc.jl files per-platform for binary distributions as well
	# Note that we don't install to sysconfdir: we always install to $(DESTDIR)$(prefix)/etc.
	# If you want to make a distribution with a hardcoded path, you take care of installation
ifeq ($(OS), Darwin)
	-cat ./contrib/mac/juliarc.jl >> $(DESTDIR)$(prefix)/etc/julia/juliarc.jl
endif

	# purge sys.{dll,so,dylib} as that file is not relocatable across processor architectures
ifeq ($(JULIA_CPU_TARGET), native)
	-rm -f $(DESTDIR)$(private_libdir)/sys.$(SHLIB_EXT)
endif

ifeq ($(OS), WINNT)
	# If we are running on WINNT, also delete sys.dll until it stops causing issues (#8895, among others)
	-rm -f $(DESTDIR)$(private_libdir)/sys.$(SHLIB_EXT)

	[ ! -d dist-extras ] || ( cd dist-extras && \
		cp 7z.exe 7z.dll libexpat-1.dll zlib1.dll $(bindir) && \
	    mkdir $(DESTDIR)$(prefix)/Git && \
	    7z x PortableGit.7z -o"$(DESTDIR)$(prefix)/Git" && \
	    echo "[core] eol = lf" >> "$(DESTDIR)$(prefix)/Git/etc/gitconfig" && \
	    sed -i "s/\bautocrlf = true$$/autocrlf = input/" "$(DESTDIR)$(prefix)/Git/etc/gitconfig" && \
	    cp busybox.exe $(DESTDIR)$(prefix)/Git/bin/echo.exe && \
	    cp busybox.exe $(DESTDIR)$(prefix)/Git/bin/printf.exe )
	cd $(DESTDIR)$(bindir) && rm -f llvm* llc.exe lli.exe opt.exe LTO.dll bugpoint.exe macho-dump.exe

	# create file listing for uninstall. note: must have Windows path separators and line endings.
	cd $(prefix) && find * | sed -e 's/\//\\/g' -e 's/$$/\r/g' > etc/uninstall.log

	# build nsis package
	$(call spawn,./dist-extras/nsis/makensis.exe) -NOCD -DVersion=$(JULIA_VERSION) -DArch=$(ARCH) -DCommit=$(JULIA_COMMIT) ./contrib/windows/build-installer.nsi

	# compress nsis installer and combine with 7zip self-extracting header
	./dist-extras/7z a -mx9 "julia-install-$(JULIA_COMMIT)-$(ARCH).7z" julia-installer.exe
	cat ./contrib/windows/7zS.sfx ./contrib/windows/7zSFX-config.txt "julia-install-$(JULIA_COMMIT)-$(ARCH).7z" > "julia-${JULIA_VERSION}-${ARCH}.exe"
	-rm -f julia-installer.exe
else
	$(TAR) zcvf $(JULIA_BINARYDIST_TARNAME).tar.gz julia-$(JULIA_COMMIT)
endif
	rm -fr $(prefix)


full-source-dist source-dist: git-submodules
	# Save git information
	-@$(MAKE) -C base version_git.jl.phony
	# Get all the dependencies downloaded
	@$(MAKE) -C deps getall

	# Create file full-source-dist.tmp to hold all the filenames that go into the tarball
	echo "base/version_git.jl" > full-source-dist.tmp
	git ls-files >> full-source-dist.tmp
	ls deps/*.tar.gz deps/*.tar.bz2 deps/*.tgz deps/*.zip >> full-source-dist.tmp
	git submodule --quiet foreach 'git ls-files | sed "s&^&$$path/&"' >> full-source-dist.tmp

	# Remove unwanted files
	sed -e '/\.git/d' -e '/\.travis/d' full-source-dist.tmp > full-source-dist.tmp1

	# Prefix everything with the current directory name (usually "julia"), then create tarball
	DIRNAME=$$(basename $$(pwd)); \
	sed -e "s_.*_$$DIRNAME/&_" full-source-dist.tmp1 > full-source-dist.tmp; \
	cd ../ && tar -cz -T $$DIRNAME/full-source-dist.tmp --no-recursion -f $$DIRNAME/julia-$(JULIA_VERSION)_$(JULIA_COMMIT).tar.gz

clean: | $(CLEAN_TARGETS)
	@$(MAKE) -C base clean
	@$(MAKE) -C src clean
	@$(MAKE) -C ui clean
	for repltype in "basic" "readline"; do \
		rm -f $(build_bindir)/julia-debug-$${repltype}; \
		rm -f $(build_bindir)/julia-$${repltype}; \
	done
	@rm -f julia
	@rm -f *~ *# *.tar.gz
	@rm -f $(build_bindir)/stringreplace full-source-dist.tmp full-source-dist.tmp1
	@rm -fr $(build_private_libdir)
# Temporarily add this line to the Makefile to remove extras
	@rm -fr $(build_datarootdir)/julia/extras

cleanall: clean
	@$(MAKE) -C src clean-flisp clean-support
	@rm -fr $(build_shlibdir)
ifeq ($(OS),WINNT)
	@rm -rf $(build_prefix)/lib
endif
	@$(MAKE) -C deps clean-uv

distcleanall: cleanall
	@$(MAKE) -C deps distcleanall
	@$(MAKE) -C doc cleanall
	rm -fr $(build_prefix)

.PHONY: default debug release julia-debug julia-release \
	test testall testall1 test-* clean distcleanall cleanall \
	run-julia run-julia-debug run-julia-release run \
	install binary-dist dist full-source-dist source-dist git-submodules

test: release
	@$(MAKE) $(QUIET_MAKE) -C test default

testall: release
	@$(MAKE) $(QUIET_MAKE) -C test all

testall1: release
	@env JULIA_CPU_CORES=1 $(MAKE) $(QUIET_MAKE) -C test all

test-%: release
	@$(MAKE) $(QUIET_MAKE) -C test $*

perf: release
	@$(MAKE) $(QUIET_MAKE) -C test/perf

perf-%: release
	@$(MAKE) $(QUIET_MAKE) -C test/perf $*

# download target for some hardcoded windows dependencies
.PHONY: win-extras wine_path
win-extras:
	[ -d dist-extras ] || mkdir dist-extras
ifneq ($(BUILD_OS),WINNT)
ifeq (,$(findstring CYGWIN,$(BUILD_OS)))
	cp /usr/lib/p7zip/7z /usr/lib/p7zip/7z.so dist-extras
endif
endif
ifneq (,$(filter $(ARCH), i386 i486 i586 i686))
	cd dist-extras && \
	$(JLDOWNLOAD) http://downloads.sourceforge.net/sevenzip/7z920.exe && \
	7z x -y 7z920.exe 7z.exe 7z.dll && \
	../contrib/windows/winrpm.sh http://download.opensuse.org/repositories/windows:/mingw:/win32/openSUSE_13.1 \
	"mingw32-libexpat1 mingw32-zlib1" && \
	cp usr/i686-w64-mingw32/sys-root/mingw/bin/*.dll .
else ifeq ($(ARCH),x86_64)
	cd dist-extras && \
	$(JLDOWNLOAD) 7z920-x64.msi http://downloads.sourceforge.net/sevenzip/7z920-x64.msi && \
	7z x -y 7z920-x64.msi _7z.exe _7z.dll && \
	mv _7z.dll 7z.dll && \
	mv _7z.exe 7z.exe && \
	../contrib/windows/winrpm.sh http://download.opensuse.org/repositories/windows:/mingw:/win64/openSUSE_13.1 \
	"mingw64-libexpat1 mingw64-zlib1" && \
	cp usr/x86_64-w64-mingw32/sys-root/mingw/bin/*.dll .
else
	$(error no win-extras target for ARCH=$(ARCH))
endif
	cd dist-extras && \
	$(JLDOWNLOAD) http://downloads.sourceforge.net/sevenzip/7z920_extra.7z && \
	$(JLDOWNLOAD) https://unsis.googlecode.com/files/nsis-2.46.5-Unicode-setup.exe && \
	$(JLDOWNLOAD) ftp://ftp.tigress.co.uk/public/gpl/6.0.0/busybox/busybox.exe && \
	chmod a+x 7z.exe && \
	chmod a+x 7z.dll && \
	$(call spawn,./7z.exe) x -y -onsis nsis-2.46.5-Unicode-setup.exe && \
	chmod a+x ./nsis/makensis.exe && \
	chmod a+x busybox.exe && \
	$(JLDOWNLOAD) PortableGit.7z https://github.com/msysgit/msysgit/releases/download/Git-1.9.5-preview20141217/PortableGit-1.9.5-preview20141217.7z
