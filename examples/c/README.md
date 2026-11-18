# NeuG Lite C API binary package

This package provides an embedded NeuG database through a self-contained C
header and one native shared library. It contains no Python/Node bindings,
HTTP server or optional extensions. Protobuf and other required third-party
code are linked into the library; only macOS system libraries are loaded
separately. C++ applications can use the same C API.

Choose a package matching your CPU architecture. `manifest.json` records the
version, build settings, macOS deployment target, system dependencies and file
hashes. The deployment target is the build's minimum OS setting; it does not
mean every macOS version has been tested. Use matching headers and library.

Before extracting, check the archive against its adjacent checksum file:

```sh
shasum -a 256 -c neug-c-api-<version>-lite-osx-<arch>.tar.gz.sha256

tar -xzf neug-c-api-<version>-lite-osx-<arch>.tar.gz
```

The two files needed by your application are:

```text
include/neug/c/neug.h    Header used when compiling your application
lib/libneug.dylib       Library used when linking and running it
```

Keep both files at those paths to use `<neug/c/neug.h>`. No other NeuG headers,
protobuf installation or NeuG source checkout is needed. The remaining files
are examples, metadata and license information.

From the extracted package root, compile and run the basic C example with a
C compiler and CMake:

```sh
cmake -S examples -B example-build -DCMAKE_PREFIX_PATH="$PWD"

cmake --build example-build

./example-build/neug_c_example
```

It prints `1 | O'Connor`. CMake sets the example's runtime library search path.
For your own application, configure the include and library directories, link
against `neug`, and set a runtime search path for the deployed library location.
The library identifies itself as `@rpath/libneug.dylib` and contains no build
machine search paths. The package has an ad-hoc signature for local loading,
not an Apple Developer ID signature or notarization; sign it as appropriate
when distributing your macOS application.

`examples/verify.c` additionally checks parameters, commit, rollback, recovery
after a query error, and persistence across separate processes. Compile it as
C or C++ (replace `cc -std=c11` with `c++ -x c++ -std=c++17`):

```sh
cc -std=c11 examples/verify.c -Iinclude -Llib -lneug \
  -Wl,-rpath,"$PWD/lib" -o verify

# Use a new, test-only database directory and the version in manifest.json.
./verify ./test-db <version> write

./verify ./test-db <version> read
```

Each command prints `PASS: C API package` followed by its phase. Callers must
check status codes, destroy query results and error objects, and close the
connection and database. See `neug.h` for ownership and transaction rules.
