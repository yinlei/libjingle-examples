# We borrow heavily from the kernel build setup, though we are simpler since
# we don't have Kconfig tweaking settings on us.

# The implicit make rules have it looking for RCS files, among other things.
# We instead explicitly write all the rules we care about.
# It's even quicker (saves ~200ms) to pass -r on the command line.
MAKEFLAGS=-r

# The source directory tree.
srcdir := .
abs_srcdir := $(abspath $(srcdir))

# The name of the builddir.
builddir_name ?= out

# The V=1 flag on command line makes us verbosely print command lines.
ifdef V
  quiet=
else
  quiet=quiet_
endif

# Specify BUILDTYPE=Release on the command line for a release build.
BUILDTYPE ?= Debug

# Directory all our build output goes into.
# Note that this must be two directories beneath src/ for unit tests to pass,
# as they reach into the src/ directory for data with relative paths.
builddir ?= $(builddir_name)/$(BUILDTYPE)
abs_builddir := $(abspath $(builddir))
depsdir := $(builddir)/.deps

# Object output directory.
obj := $(builddir)/obj
abs_obj := $(abspath $(obj))

# We build up a list of every single one of the targets so we can slurp in the
# generated dependency rule Makefiles in one pass.
all_deps :=



# C++ apps need to be linked with g++.
#
# Note: flock is used to seralize linking. Linking is a memory-intensive
# process so running parallel links can often lead to thrashing.  To disable
# the serialization, override LINK via an envrionment variable as follows:
#
#   export LINK=g++
#
# This will allow make to invoke N linker processes as specified in -jN.
LINK ?= flock $(builddir)/linker.lock $(CXX.target)

CC.target ?= $(CC)
CFLAGS.target ?= $(CFLAGS)
CXX.target ?= $(CXX)
CXXFLAGS.target ?= $(CXXFLAGS)
LINK.target ?= $(LINK)
LDFLAGS.target ?= $(LDFLAGS)
AR.target ?= $(AR)

# TODO(evan): move all cross-compilation logic to gyp-time so we don't need
# to replicate this environment fallback in make as well.
CC.host ?= gcc
CFLAGS.host ?=
CXX.host ?= g++
CXXFLAGS.host ?=
LINK.host ?= g++
LDFLAGS.host ?=
AR.host ?= ar

# Define a dir function that can handle spaces.
# http://www.gnu.org/software/make/manual/make.html#Syntax-of-Functions
# "leading spaces cannot appear in the text of the first argument as written.
# These characters can be put into the argument value by variable substitution."
empty :=
space := $(empty) $(empty)

# http://stackoverflow.com/questions/1189781/using-make-dir-or-notdir-on-a-path-with-spaces
replace_spaces = $(subst $(space),?,$1)
unreplace_spaces = $(subst ?,$(space),$1)
dirx = $(call unreplace_spaces,$(dir $(call replace_spaces,$1)))

# Flags to make gcc output dependency info.  Note that you need to be
# careful here to use the flags that ccache and distcc can understand.
# We write to a dep file on the side first and then rename at the end
# so we can't end up with a broken dep file.
depfile = $(depsdir)/$(call replace_spaces,$@).d
DEPFLAGS = -MMD -MF $(depfile).raw

# We have to fixup the deps output in a few ways.
# (1) the file output should mention the proper .o file.
# ccache or distcc lose the path to the target, so we convert a rule of
# the form:
#   foobar.o: DEP1 DEP2
# into
#   path/to/foobar.o: DEP1 DEP2
# (2) we want missing files not to cause us to fail to build.
# We want to rewrite
#   foobar.o: DEP1 DEP2 \
#               DEP3
# to
#   DEP1:
#   DEP2:
#   DEP3:
# so if the files are missing, they're just considered phony rules.
# We have to do some pretty insane escaping to get those backslashes
# and dollar signs past make, the shell, and sed at the same time.
# Doesn't work with spaces, but that's fine: .d files have spaces in
# their names replaced with other characters.
define fixup_dep
# The depfile may not exist if the input file didn't have any #includes.
touch $(depfile).raw
# Fixup path as in (1).
sed -e "s|^$(notdir $@)|$@|" $(depfile).raw >> $(depfile)
# Add extra rules as in (2).
# We remove slashes and replace spaces with new lines;
# remove blank lines;
# delete the first line and append a colon to the remaining lines.
sed -e 's|\\||' -e 'y| |\n|' $(depfile).raw |\
  grep -v '^$$'                             |\
  sed -e 1d -e 's|$$|:|'                     \
    >> $(depfile)
rm $(depfile).raw
endef

# Command definitions:
# - cmd_foo is the actual command to run;
# - quiet_cmd_foo is the brief-output summary of the command.

quiet_cmd_cc = CC($(TOOLSET)) $@
cmd_cc = $(CC.$(TOOLSET)) $(GYP_CFLAGS) $(DEPFLAGS) $(CFLAGS.$(TOOLSET)) -c -o $@ $<

quiet_cmd_cxx = CXX($(TOOLSET)) $@
cmd_cxx = $(CXX.$(TOOLSET)) $(GYP_CXXFLAGS) $(DEPFLAGS) $(CXXFLAGS.$(TOOLSET)) -c -o $@ $<

quiet_cmd_touch = TOUCH $@
cmd_touch = touch $@

quiet_cmd_copy = COPY $@
# send stderr to /dev/null to ignore messages when linking directories.
cmd_copy = ln -f "$<" "$@" 2>/dev/null || (rm -rf "$@" && cp -af "$<" "$@")

quiet_cmd_alink = AR($(TOOLSET)) $@
cmd_alink = rm -f $@ && $(AR.$(TOOLSET)) crs $@ $(filter %.o,$^)

quiet_cmd_alink_thin = AR($(TOOLSET)) $@
cmd_alink_thin = rm -f $@ && $(AR.$(TOOLSET)) crsT $@ $(filter %.o,$^)

# Due to circular dependencies between libraries :(, we wrap the
# special "figure out circular dependencies" flags around the entire
# input list during linking.
quiet_cmd_link = LINK($(TOOLSET)) $@
cmd_link = $(LINK.$(TOOLSET)) $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -o $@ -Wl,--start-group $(LD_INPUTS) -Wl,--end-group $(LIBS)

# We support two kinds of shared objects (.so):
# 1) shared_library, which is just bundling together many dependent libraries
# into a link line.
# 2) loadable_module, which is generating a module intended for dlopen().
#
# They differ only slightly:
# In the former case, we want to package all dependent code into the .so.
# In the latter case, we want to package just the API exposed by the
# outermost module.
# This means shared_library uses --whole-archive, while loadable_module doesn't.
# (Note that --whole-archive is incompatible with the --start-group used in
# normal linking.)

# Other shared-object link notes:
# - Set SONAME to the library filename so our binaries don't reference
# the local, absolute paths used on the link command-line.
quiet_cmd_solink = SOLINK($(TOOLSET)) $@
cmd_solink = $(LINK.$(TOOLSET)) -shared $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -Wl,-soname=$(@F) -o $@ -Wl,--whole-archive $(LD_INPUTS) -Wl,--no-whole-archive $(LIBS)

quiet_cmd_solink_module = SOLINK_MODULE($(TOOLSET)) $@
cmd_solink_module = $(LINK.$(TOOLSET)) -shared $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -Wl,-soname=$(@F) -o $@ -Wl,--start-group $(filter-out FORCE_DO_CMD, $^) -Wl,--end-group $(LIBS)


# Define an escape_quotes function to escape single quotes.
# This allows us to handle quotes properly as long as we always use
# use single quotes and escape_quotes.
escape_quotes = $(subst ','\'',$(1))
# This comment is here just to include a ' to unconfuse syntax highlighting.
# Define an escape_vars function to escape '$' variable syntax.
# This allows us to read/write command lines with shell variables (e.g.
# $LD_LIBRARY_PATH), without triggering make substitution.
escape_vars = $(subst $$,$$$$,$(1))
# Helper that expands to a shell command to echo a string exactly as it is in
# make. This uses printf instead of echo because printf's behaviour with respect
# to escape sequences is more portable than echo's across different shells
# (e.g., dash, bash).
exact_echo = printf '%s\n' '$(call escape_quotes,$(1))'

# Helper to compare the command we're about to run against the command
# we logged the last time we ran the command.  Produces an empty
# string (false) when the commands match.
# Tricky point: Make has no string-equality test function.
# The kernel uses the following, but it seems like it would have false
# positives, where one string reordered its arguments.
#   arg_check = $(strip $(filter-out $(cmd_$(1)), $(cmd_$@)) \
#                       $(filter-out $(cmd_$@), $(cmd_$(1))))
# We instead substitute each for the empty string into the other, and
# say they're equal if both substitutions produce the empty string.
# .d files contain ? instead of spaces, take that into account.
command_changed = $(or $(subst $(cmd_$(1)),,$(cmd_$(call replace_spaces,$@))),\
                       $(subst $(cmd_$(call replace_spaces,$@)),,$(cmd_$(1))))

# Helper that is non-empty when a prerequisite changes.
# Normally make does this implicitly, but we force rules to always run
# so we can check their command lines.
#   $? -- new prerequisites
#   $| -- order-only dependencies
prereq_changed = $(filter-out FORCE_DO_CMD,$(filter-out $|,$?))

# Helper that executes all postbuilds until one fails.
define do_postbuilds
  @E=0;\
  for p in $(POSTBUILDS); do\
    eval $$p;\
    E=$$?;\
    if [ $$E -ne 0 ]; then\
      break;\
    fi;\
  done;\
  if [ $$E -ne 0 ]; then\
    rm -rf "$@";\
    exit $$E;\
  fi
endef

# do_cmd: run a command via the above cmd_foo names, if necessary.
# Should always run for a given target to handle command-line changes.
# Second argument, if non-zero, makes it do asm/C/C++ dependency munging.
# Third argument, if non-zero, makes it do POSTBUILDS processing.
# Note: We intentionally do NOT call dirx for depfile, since it contains ? for
# spaces already and dirx strips the ? characters.
define do_cmd
$(if $(or $(command_changed),$(prereq_changed)),
  @$(call exact_echo,  $($(quiet)cmd_$(1)))
  @mkdir -p "$(call dirx,$@)" "$(dir $(depfile))"
  $(if $(findstring flock,$(word 1,$(cmd_$1))),
    @$(cmd_$(1))
    @echo "  $(quiet_cmd_$(1)): Finished",
    @$(cmd_$(1))
  )
  @$(call exact_echo,$(call escape_vars,cmd_$(call replace_spaces,$@) := $(cmd_$(1)))) > $(depfile)
  @$(if $(2),$(fixup_dep))
  $(if $(and $(3), $(POSTBUILDS)),
    $(call do_postbuilds)
  )
)
endef

# Declare the "all" target first so it is the default,
# even though we don't have the deps yet.
.PHONY: all
all:

# make looks for ways to re-generate included makefiles, but in our case, we
# don't have a direct way. Explicitly telling make that it has nothing to do
# for them makes it go faster.
%.d: ;

# Use FORCE_DO_CMD to force a target to run.  Should be coupled with
# do_cmd.
.PHONY: FORCE_DO_CMD
FORCE_DO_CMD:

TOOLSET := host
# Suffix rules, putting all outputs into $(obj).
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

# Try building from generated source, too.
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

$(obj).$(TOOLSET)/%.o: $(obj)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

TOOLSET := target
# Suffix rules, putting all outputs into $(obj).
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

# Try building from generated source, too.
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

$(obj).$(TOOLSET)/%.o: $(obj)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)


ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/All.target.mk)))),)
  include talk/All.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/gunit.target.mk)))),)
  include talk/gunit.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle.target.mk)))),)
  include talk/libjingle.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_media.target.mk)))),)
  include talk/libjingle_media.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_media_unittest.target.mk)))),)
  include talk/libjingle_media_unittest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_p2p.target.mk)))),)
  include talk/libjingle_p2p.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_p2p_unittest.target.mk)))),)
  include talk/libjingle_p2p_unittest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_peerconnection.target.mk)))),)
  include talk/libjingle_peerconnection.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_peerconnection_unittest.target.mk)))),)
  include talk/libjingle_peerconnection_unittest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_sound.target.mk)))),)
  include talk/libjingle_sound.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_sound_unittest.target.mk)))),)
  include talk/libjingle_sound_unittest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_unittest.target.mk)))),)
  include talk/libjingle_unittest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_unittest_main.target.mk)))),)
  include talk/libjingle_unittest_main.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/libjingle_xmpphelp.target.mk)))),)
  include talk/libjingle_xmpphelp.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/login.target.mk)))),)
  include talk/login.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/peerconnection_client.target.mk)))),)
  include talk/peerconnection_client.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/peerconnection_server.target.mk)))),)
  include talk/peerconnection_server.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/relayserver.target.mk)))),)
  include talk/relayserver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,talk/stunserver.target.mk)))),)
  include talk/stunserver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/expat/expat.target.mk)))),)
  include third_party/expat/expat.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/jsoncpp/jsoncpp.target.mk)))),)
  include third_party/jsoncpp/jsoncpp.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libjpeg_turbo/libjpeg.target.mk)))),)
  include third_party/libjpeg_turbo/libjpeg.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/libsrtp.target.mk)))),)
  include third_party/libsrtp/libsrtp.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/rdbx_driver.target.mk)))),)
  include third_party/libsrtp/rdbx_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/replay_driver.target.mk)))),)
  include third_party/libsrtp/replay_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/roc_driver.target.mk)))),)
  include third_party/libsrtp/roc_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/rtpw.target.mk)))),)
  include third_party/libsrtp/rtpw.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_driver.target.mk)))),)
  include third_party/libsrtp/srtp_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_runtest.target.mk)))),)
  include third_party/libsrtp/srtp_runtest.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_aes_calc.target.mk)))),)
  include third_party/libsrtp/srtp_test_aes_calc.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_cipher_driver.target.mk)))),)
  include third_party/libsrtp/srtp_test_cipher_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_datatypes_driver.target.mk)))),)
  include third_party/libsrtp/srtp_test_datatypes_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_env.target.mk)))),)
  include third_party/libsrtp/srtp_test_env.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_kernel_driver.target.mk)))),)
  include third_party/libsrtp/srtp_test_kernel_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_rand_gen.target.mk)))),)
  include third_party/libsrtp/srtp_test_rand_gen.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_sha1_driver.target.mk)))),)
  include third_party/libsrtp/srtp_test_sha1_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libsrtp/srtp_test_stat_driver.target.mk)))),)
  include third_party/libsrtp/srtp_test_stat_driver.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/gen_asm_offsets_vp8.target.mk)))),)
  include third_party/libvpx/gen_asm_offsets_vp8.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/gen_asm_offsets_vp9.target.mk)))),)
  include third_party/libvpx/gen_asm_offsets_vp9.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/gen_asm_offsets_vpx_scale.target.mk)))),)
  include third_party/libvpx/gen_asm_offsets_vpx_scale.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx.target.mk)))),)
  include third_party/libvpx/libvpx.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx_asm_offsets.target.mk)))),)
  include third_party/libvpx/libvpx_asm_offsets.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx_asm_offsets_vp9.target.mk)))),)
  include third_party/libvpx/libvpx_asm_offsets_vp9.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx_asm_offsets_vpx_scale.target.mk)))),)
  include third_party/libvpx/libvpx_asm_offsets_vpx_scale.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx_intrinsics.target.mk)))),)
  include third_party/libvpx/libvpx_intrinsics.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/libvpx_obj_int_extract.host.mk)))),)
  include third_party/libvpx/libvpx_obj_int_extract.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/simple_decoder.target.mk)))),)
  include third_party/libvpx/simple_decoder.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libvpx/simple_encoder.target.mk)))),)
  include third_party/libvpx/simple_encoder.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/libyuv/libyuv.target.mk)))),)
  include third_party/libyuv/libyuv.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/opus/opus.target.mk)))),)
  include third_party/opus/opus.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/protobuf_full_do_not_use.host.mk)))),)
  include third_party/protobuf/protobuf_full_do_not_use.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/protobuf_full_do_not_use.target.mk)))),)
  include third_party/protobuf/protobuf_full_do_not_use.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/protobuf_lite.host.mk)))),)
  include third_party/protobuf/protobuf_lite.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/protobuf_lite.target.mk)))),)
  include third_party/protobuf/protobuf_lite.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/protoc.host.mk)))),)
  include third_party/protobuf/protoc.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/protobuf/py_proto.target.mk)))),)
  include third_party/protobuf/py_proto.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/common_audio/resampler.target.mk)))),)
  include third_party/webrtc/common_audio/resampler.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/common_audio/signal_processing.target.mk)))),)
  include third_party/webrtc/common_audio/signal_processing.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/common_audio/vad.target.mk)))),)
  include third_party/webrtc/common_audio/vad.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/common_video/common_video.target.mk)))),)
  include third_party/webrtc/common_video/common_video.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/CNG.target.mk)))),)
  include third_party/webrtc/modules/CNG.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/G711.target.mk)))),)
  include third_party/webrtc/modules/G711.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/G722.target.mk)))),)
  include third_party/webrtc/modules/G722.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/NetEq.target.mk)))),)
  include third_party/webrtc/modules/NetEq.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/NetEq4.target.mk)))),)
  include third_party/webrtc/modules/NetEq4.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/PCM16B.target.mk)))),)
  include third_party/webrtc/modules/PCM16B.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audio_coding_module.target.mk)))),)
  include third_party/webrtc/modules/audio_coding_module.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audio_conference_mixer.target.mk)))),)
  include third_party/webrtc/modules/audio_conference_mixer.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audio_device.target.mk)))),)
  include third_party/webrtc/modules/audio_device.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audio_processing.target.mk)))),)
  include third_party/webrtc/modules/audio_processing.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audio_processing_sse2.target.mk)))),)
  include third_party/webrtc/modules/audio_processing_sse2.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/audioproc_debug_proto.target.mk)))),)
  include third_party/webrtc/modules/audioproc_debug_proto.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/bitrate_controller.target.mk)))),)
  include third_party/webrtc/modules/bitrate_controller.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/iLBC.target.mk)))),)
  include third_party/webrtc/modules/iLBC.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/iSAC.target.mk)))),)
  include third_party/webrtc/modules/iSAC.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/iSACFix.target.mk)))),)
  include third_party/webrtc/modules/iSACFix.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/media_file.target.mk)))),)
  include third_party/webrtc/modules/media_file.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/paced_sender.target.mk)))),)
  include third_party/webrtc/modules/paced_sender.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/remote_bitrate_estimator.target.mk)))),)
  include third_party/webrtc/modules/remote_bitrate_estimator.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/rtp_rtcp.target.mk)))),)
  include third_party/webrtc/modules/rtp_rtcp.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/udp_transport.target.mk)))),)
  include third_party/webrtc/modules/udp_transport.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_capture_module.target.mk)))),)
  include third_party/webrtc/modules/video_capture_module.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_coding/codecs/vp8/webrtc_vp8.target.mk)))),)
  include third_party/webrtc/modules/video_coding/codecs/vp8/webrtc_vp8.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_coding/utility/video_coding_utility.target.mk)))),)
  include third_party/webrtc/modules/video_coding/utility/video_coding_utility.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_processing.target.mk)))),)
  include third_party/webrtc/modules/video_processing.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_processing_sse2.target.mk)))),)
  include third_party/webrtc/modules/video_processing_sse2.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/video_render_module.target.mk)))),)
  include third_party/webrtc/modules/video_render_module.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/webrtc_i420.target.mk)))),)
  include third_party/webrtc/modules/webrtc_i420.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/webrtc_opus.target.mk)))),)
  include third_party/webrtc/modules/webrtc_opus.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/webrtc_utility.target.mk)))),)
  include third_party/webrtc/modules/webrtc_utility.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/modules/webrtc_video_coding.target.mk)))),)
  include third_party/webrtc/modules/webrtc_video_coding.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/system_wrappers/source/system_wrappers.target.mk)))),)
  include third_party/webrtc/system_wrappers/source/system_wrappers.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/video_engine/video_engine_core.target.mk)))),)
  include third_party/webrtc/video_engine/video_engine_core.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/webrtc/voice_engine/voice_engine_core.target.mk)))),)
  include third_party/webrtc/voice_engine/voice_engine_core.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/config_sources.host.mk)))),)
  include third_party/yasm/config_sources.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/generate_files.host.mk)))),)
  include third_party/yasm/generate_files.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genmacro.host.mk)))),)
  include third_party/yasm/genmacro.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genmodule.host.mk)))),)
  include third_party/yasm/genmodule.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genperf.host.mk)))),)
  include third_party/yasm/genperf.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genperf_libs.host.mk)))),)
  include third_party/yasm/genperf_libs.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genstring.host.mk)))),)
  include third_party/yasm/genstring.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/genversion.host.mk)))),)
  include third_party/yasm/genversion.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/re2c.host.mk)))),)
  include third_party/yasm/re2c.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,third_party/yasm/yasm.host.mk)))),)
  include third_party/yasm/yasm.host.mk
endif

quiet_cmd_regen_makefile = ACTION Regenerating $@
cmd_regen_makefile = ./build/gyp_chromium -fmake --ignore-environment "--toplevel-dir=." -I/vagrant/trunk/build/common.gypi -I/vagrant/trunk/talk/supplement.gypi "--depth=." "-Dextra_gyp_flag=0" talk/libjingle_all.gyp
Makefile: third_party/webrtc/modules/audio_coding/neteq/neteq.gypi third_party/webrtc/modules/media_file/source/media_file.gypi third_party/webrtc/modules/audio_processing/audio_processing.gypi third_party/webrtc/modules/video_processing/main/source/video_processing.gypi third_party/expat/expat.gyp third_party/webrtc/modules/audio_coding/codecs/ilbc/ilbc.gypi third_party/webrtc/modules/utility/source/utility.gypi third_party/yasm/yasm_compile.gypi third_party/webrtc/modules/audio_coding/codecs/pcm16b/pcm16b.gypi build/internal/release_impl_official.gypi build/ios/mac_build.gypi third_party/webrtc/common_audio/resampler/resampler.gypi third_party/webrtc/voice_engine/test/voice_engine_tests.gypi talk/libjingle_all.gyp third_party/libyuv/libyuv.gyp third_party/webrtc/modules/audio_coding/codecs/isac/main/source/isac.gypi third_party/webrtc/modules/video_processing/main/test/vpm_tests.gypi third_party/webrtc/voice_engine/voice_engine_core.gypi third_party/webrtc/common_audio/vad/vad.gypi third_party/libvpx/libvpx_srcs_x86.gypi third_party/opus/opus.gyp third_party/libvpx/libvpx_srcs_mips.gypi third_party/webrtc/modules/video_coding/codecs/test_framework/test_framework.gypi third_party/webrtc/build/protoc.gypi third_party/webrtc/build/common.gypi third_party/webrtc/modules/rtp_rtcp/source/rtp_rtcp_tests.gypi talk/libjingle.gyp third_party/webrtc/modules/rtp_rtcp/test/testFec/test_fec.gypi third_party/webrtc/modules/video_coding/utility/video_coding_utility.gyp third_party/yasm/yasm.gyp third_party/webrtc/modules/audio_coding/codecs/isac/fix/source/isacfix.gypi third_party/webrtc/modules/audio_coding/main/source/audio_coding_module.gypi build/release.gypi third_party/webrtc/common_audio/common_audio.gyp third_party/webrtc/modules/audio_processing/audio_processing_tests.gypi third_party/webrtc/modules/modules.gyp third_party/webrtc/video_engine/test/libvietest/libvietest.gypi third_party/webrtc/modules/video_coding/codecs/i420/main/source/i420.gypi third_party/webrtc/modules/audio_coding/codecs/g722/g722.gypi third_party/protobuf/protobuf_lite.gypi talk/libjingle_tests.gyp third_party/webrtc/video_engine/video_engine.gyp talk/supplement.gypi third_party/webrtc/modules/pacing/pacing.gypi third_party/webrtc/modules/udp_transport/source/udp_transport.gypi build/grit_action.gypi third_party/webrtc/system_wrappers/source/system_wrappers.gyp third_party/protobuf/protobuf.gyp third_party/webrtc/modules/audio_coding/neteq4/neteq_tests.gypi third_party/webrtc/modules/video_render/video_render.gypi talk/libjingle_examples.gyp third_party/webrtc/modules/video_coding/codecs/vp8/vp8.gyp third_party/webrtc/modules/audio_coding/codecs/cng/cng.gypi third_party/webrtc/common_audio/signal_processing/signal_processing.gypi third_party/webrtc/video_engine/test/auto_test/vie_auto_test.gypi build/internal/release_defaults.gypi third_party/webrtc/modules/rtp_rtcp/source/rtp_rtcp.gypi build/shim_headers.gypi third_party/libvpx/libvpx_srcs_arm_neon.gypi third_party/libsrtp/libsrtp.gyp build/java.gypi third_party/webrtc/common_video/common_video.gyp third_party/webrtc/modules/video_coding/main/source/video_coding.gypi third_party/webrtc/modules/video_capture/video_capture.gypi third_party/libvpx/libvpx.gyp third_party/webrtc/modules/audio_coding/neteq4/neteq.gypi third_party/webrtc/video_engine/video_engine_core.gypi third_party/webrtc/modules/audio_coding/codecs/g711/g711.gypi third_party/libjpeg_turbo/libjpeg.gyp third_party/webrtc/modules/audio_coding/codecs/opus/opus.gypi third_party/libvpx/libvpx_srcs_arm.gypi build/filename_rules.gypi third_party/jsoncpp/jsoncpp.gyp third_party/webrtc/modules/remote_bitrate_estimator/remote_bitrate_estimator.gypi third_party/webrtc/modules/video_coding/codecs/tools/video_codecs_tools.gypi build/internal/release_impl.gypi third_party/libvpx/libvpx_srcs_x86_64.gypi third_party/webrtc/build/generate_asm_header.gypi third_party/webrtc/modules/audio_coding/codecs/isac/isac_test.gypi third_party/webrtc/voice_engine/voice_engine.gyp third_party/webrtc/modules/audio_conference_mixer/source/audio_conference_mixer.gypi third_party/webrtc/modules/video_coding/main/source/video_coding_test.gypi third_party/webrtc/modules/bitrate_controller/bitrate_controller.gypi build/common.gypi third_party/webrtc/build/arm_neon.gypi third_party/webrtc/modules/audio_coding/codecs/isac/isacfix_test.gypi talk/build/common.gypi third_party/webrtc/modules/audio_device/audio_device.gypi third_party/webrtc/modules/video_coding/codecs/test/video_codecs_test_framework.gypi
	$(call do_cmd,regen_makefile)

# "all" is a concatenation of the "all" targets from all the included
# sub-makefiles. This is just here to clarify.
all:

# Add in dependency-tracking rules.  $(all_deps) is the list of every single
# target in our tree. Only consider the ones with .d (dependency) info:
d_files := $(wildcard $(foreach f,$(all_deps),$(depsdir)/$(f).d))
ifneq ($(d_files),)
  include $(d_files)
endif
