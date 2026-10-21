# Setup file for Kilo Code AI to enable build of guardrail code
# Source this file.  
current_dir=$(pwd)
cd /exp/dune/app/users/esnider/code-spack/larsoft3/mpdtest
source subspack/setup-env.sh
spack mpd select mpddev
spack env activate local
cd ${current_dir}
