# Patch to use dynamic OpenSSL instead of static
# This gets applied during the build process
set(OPENSSL_USE_STATIC_LIBS OFF CACHE BOOL "Use dynamic OpenSSL" FORCE)
