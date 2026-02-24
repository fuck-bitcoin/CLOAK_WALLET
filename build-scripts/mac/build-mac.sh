export BUILD_DIR=$PWD
pushd $HOME

rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin
popd

git clone -b "$1" --depth 1 https://github.com/flutter/flutter.git flutter
flutter doctor -v

cargo b -r --target=x86_64-apple-darwin --features=dart_ffi,sqlcipher
cargo b -r --target=aarch64-apple-darwin --features=dart_ffi,sqlcipher

mkdir -p target/universal/release
lipo target/x86_64-apple-darwin/release/libzeos_caterpillar.dylib target/aarch64-apple-darwin/release/libzeos_caterpillar.dylib -output target/universal/release/libzeos_caterpillar.dylib -create

./configure.sh
flutter build macos
