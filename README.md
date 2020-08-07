# Knossos-KSC.  

#### Compile a lisp-like IR with automatic differentiation and user-defined rewrites.

This project is a functional compiler and code-gen tool that will
accelerate writing AI algorithms as well as making them easier.   The core is a lisp-like IR that can be translated from high-level 
languages, and can be linked to a variety of backends to generate code.

Currently implemented frontends are
 * Julia: j2ks
 * F#: f2k
 * TorchScript: ts2k
 * KS-Lisp: The IR itself is exchanged in a lisp-like text format (see below).  

Current backends:
 * CPU/C++: Written in Haskell KSC CGen.hs
 * GPU/Futhark: Also in Haskell KSC
 * MLIR: Written in C++ /mlir folder

Current transformers:
 * KSC: Various Autodiff and optimization transforms, in Haskell 

#### KS-Lisp: A low-sugar IR

It is not particularly intended to be user-friendly, and is "low sugar",  but lispers may like to play with it.  There's a VS Code extension in etc/ks-vscode.

The lisp-like IR is extremely simple -- all the language builtins are 
in this code:
```lisp
;; Externally defined function "sqrt" returns a Float, takes two Float
(edef atan2 Float (Float Float)) 

#| Block comments
 -- User-defined function f 
 takes an Integer and Vector of (Float Float) pairs
 and returns a Float
|#
(def f Float ((i : Integer) (v : Vector (Tuple Float Float)))
  (assert (gt i 0) ; (assert TEST BODY)
     (if (eq i 0)  ; (if TEST THENBODY ELSEBODY)
        ; "then" branch
        (let (tmp (index 0 v)) ; (let (VAR VAL) BODY)
           (mul (get$1 tmp) 2.0)) ; no builtins -- e.g. mul is a function
        ; "else" branch
        (let ((t1 (index 0 v)) ; (let ((VAR1 VAL1) ... (VARn VALn)) BODY)
              (t2 (f (sub i 1) v)))
          t2))))

;; Rewrite rule
(rule "mul.commute" ((a : Float) (b : Float)) (mul a b) (mul b a))

;; And compilation produces f and its derivative, as if
(edef rev$f
    (Tuple (Tuple) (Vector (Tuple Float Float))) ; df is tangent-type of inputs (dInteger = void)
    (Tuple (i : Integer) (v : Vector (Tuple Float Float))) ; inputs in a tuple
    (df: Float)) ; df    
```
See [the ksc syntax primer](test/ksc/syntax-primer.ks) for an
introduction to the syntax of `.ks` files.  [The ksc test
directory](test/ksc) provides more examples of the constructs
available when writing `.ks` files.


## INSTALLATION/BUILDING

### If you experience any difficulty getting started

Knossos will only be a successful project if the onboarding experience
is straightforward.  We consider any difficulty getting started whilst
following these instructions to be a critical issue that we should fix
urgently.  Therefore if you experience any difficulty getting started
please follow these steps:

1. [File an
issue](https://github.com/microsoft/knossos-ksc/issues/new) with the
title "Difficulty onboarding" that explains as much as possible about
the difficulty you are having.

2. Email knossos@service.microsoft.com with the subject "Urgent:
difficulty onboarding to knossos-ksc" with a link to the new issue you
just filed.

We will respond to you as a matter of top priority.

### Please report your experience onboarding

Please report your experience of onboarding, regardless of whether it
was good or bad.  It is hard to test onboarding automatically and so
we rely on new users to tell us about their experience.  After
following this guide, whether you were successful or not, please

* [File an issue](https://github.com/microsoft/knossos-ksc/issues/new)
  with the title "Experience report: new user onboarding" describing
  how you found your onboarding experience.

Many thanks, the Knossos team.

## Installing dependencies

Knossos `ksc` requires reasonably up-to-date versions of ghc, cabal
and g++.   The following are sufficient

* ghc version >= 8.4
* cabal version >= 3.0
* g++ version >= 7

This section describes how to get them.

### Windows
Install [Chocolatey](https://chocolatey.org/), then:
```cmd
choco install ghc --version 8.6.5 -y
cabal v2-update
choco install mingw --version 7.3.0 -y
choco install msys2
refreshenv
```

### Ubuntu

You ought to use Ubuntu version >= 18.04 because older Ubuntus don't
have g++ >= 7.  Ubuntu 18.04 under WSL works perfectly fine.  The
simplest way to get ghc and cabal is to install specific versions
using [ghcup](https://gitlab.haskell.org/haskell/ghcup) as detailed
below.

```sh
sudo apt-get update
sudo apt-get install build-essential libgmp-dev

# NB Installing 8.6.5 has copious ouput
curl https://raw.githubusercontent.com/haskell/ghcup/c2bc5941f076f1fa9c62169f6217acac8dd62fc8/ghcup > ghcup
sh ./ghcup install 8.6.5
sh ./ghcup install-cabal 3.0.0.0
~/.ghcup/bin/cabal v2-update
```

### Cloning knossos

```
git clone https://github.com/microsoft/knossos-ksc
cd knossos-ksc
```

## Building

Build knossos in the `knossos-ksc` folder as follows.  If the
versions of ghc and cabal you installed above are on your `PATH` then
it will be sufficient to do

```sh
cabal v2-build --ghc-option=-Wwarn
```

`choco` users on Windows should find that cabal and ghc are already on
their `PATH` so that command will run fine.  Ubuntu users might need
to use the following, more explicit, command line.

```
~/.ghcup/bin/cabal v2-build --ghc-option=-Wwarn --with-ghc ~/.ghcup/ghc/8.6.5/bin/ghc
```

It will build a lot of packages, which will look a bit like

```
- call-stack-0.2.0 (lib) (requires build)
...
Starting     setenv-0.1.1.3 (lib)
Starting     hspec-discover-2.7.1 (lib)
...
Building     primitive-0.7.0.0 (lib)
...
Installing   setenv-0.1.1.3 (lib)
...
Completed    setenv-0.1.1.3 (lib)
...
```

Then it will build knossos.

## The ksc executable

### Compiling the ksc executable

To create the `ksc` executable run the following.  If the versions of
ghc and cabal you installed above are on your `PATH` then it will be
sufficient to do

```
# Delete the old ksc binary, if it exists
rm ksc
cabal v2-install --installdir=.
```

Those who installed cabal and ghc via ghcup might need to use the
following, more explicit, command line.

```
# Delete the old ksc binary, if it exists
rm ksc
~/.ghcup/bin/cabal v2-install --with-ghc ~/.ghcup/ghc/8.6.5/bin/ghc --installdir=.
```

### Running the ksc executable

#### Running

Run the `ksc` executable as follows to differentiate, compile and run
a `.ks` program.  This example runs `hello-world.ks`.

```
./ksc --compile-and-run \
  --ks-source-file src/runtime/prelude.ks \
  --ks-source-file test/ksc/hello-world.ks \
  --ks-output-file obj/test/ksc/hello-world.kso \
  --cpp-output-file obj/test/ksc/hello-world.cpp \
  --c++ g++ \
  --exe-output-file obj/test/ksc/hello-world.exe
```

or with PowerShell syntax:

```
./ksc --compile-and-run `
  --ks-source-file src/runtime/prelude.ks `
  --ks-source-file test/ksc/hello-world.ks `
  --ks-output-file obj/test/ksc/hello-world.kso `
  --cpp-output-file obj/test/ksc/hello-world.cpp `
  --c++ g++ `
  --exe-output-file obj/test/ksc/hello-world.exe
```

#### Tests

To run the ksc self-tests use the command line

```
./ksc --test --fs-test out.fs
```

(Don't worry if the final test, of `out.fs`, fails.  It is a test for
F#-to-ks, which most users will not have set up.)

#### Generating a `.kso` file from a `.ks` file without differentiating

To generate a `.kso` file from a `.ks` file without differentiating,
i.e. to type check and apply ksc's heuristic optimisations, use the
command line

```
./ksc --generate-cpp-without-diffs \
  --ks-source-file src/runtime/prelude.ks \
  --ks-source-file input.ks \
  --ks-output-file output.ks \
  --cpp-output-file output.cpp
```

## ksc basics

### Syntax of .ks files

In the compiler, the IR is defined in [`Lang.hs`](src/ksc/Lang.hs).
The syntax is defined by the parser in
[`Parse.hs`](src/ksc/Parse.hs) and the pretty-printer in
[`Lang.hs`](src/ksc/Lang.hs).  `testRoundTrip` in
[`Main.hs`](src/ksc/Main.hs) checks that they agree.

### Compiler pipeline

The compiler works by parsing the source code, generating forward and
reverse mode automatic derivatives, and then applying some
optimisations before emitting the code to backend.

The main backend is C++ (defined in [`Cgen.hs`](src/ksc/Cgen.hs)).
It depends on a small runtime (defined in
[`src/runtime/knossos.h`](src/runtime/knossos.h)) which provides a
bump-allocated vector
implementation, implementations of primitives, and a very small
standard library called the "prelude".

We also have a [Futhark](https://futhark-lang.org/) backend, but most
of our efforts are concentrated on C++ at the moment.

## Code of Conduct

Collaboration on this project is subject to the [Microsoft Open Source
Code of Conduct](https://opensource.microsoft.com/codeofconduct).
