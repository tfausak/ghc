# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://ghc.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://ghc.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------

utils/hpc_USES_CABAL                   = YES
utils/hpc_PACKAGE                      = hpc-bin

# built by ghc-stage0
utils/hpc_dist_INSTALL_INPLACE         = NO
utils/hpc_dist_PROGNAME                = hpc
utils/hpc_dist_SHELL_WRAPPER           = YES
utils/hpc_dist_INSTALL_SHELL_WRAPPER_NAME = hpc

# built by ghc-stage1
utils/hpc_dist-install_INSTALL_INPLACE = YES
utils/hpc_dist-install_PROGNAME        = hpc
utils/hpc_dist-install_SHELL_WRAPPER   = YES
utils/hpc_dist-install_INSTALL_SHELL_WRAPPER_NAME = hpc

ifeq "$(Stage1Only)" "YES"
utils/hpc_dist_INSTALL                 = YES
utils/hpc_dist-install_INSTALL         = NO
else
utils/hpc_dist_INSTALL                 = NO
utils/hpc_dist-install_INSTALL         = YES
endif

$(eval $(call build-prog,utils/hpc,dist,0))
$(eval $(call build-prog,utils/hpc,dist-install,1))
