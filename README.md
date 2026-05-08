# Lizard
### The c code of the Public Key Encryption scheme Lizard

Lizard is a public key encryption scheme based on the Learning with Errors(LWE) problem and the Learning with Rounding(LWR) problem.

The code consists of IND-CPA Lizard and IND-CCA Lizard, which are included in a single c file.

To build the code, the following commands are sufficient :

`
$ make clean 
$ make all
`

Or equivalently,

`
$ make new
`

Note that the AVX2 optimization is included in our compile options. For the implementation on the machines without AVX2 instruction, you can erase an AVX2 option -mavx2 before running the code.

## Benchmarking CCALizard KEM

Use the one-click benchmark script to compare a portable reference-style build with the repository's AVX2-enabled optimized build:

```sh
./scripts/benchmark_ccalizard.sh
```

The script builds and runs `PARAMS_CCA`, which is the only CCALizard KEM parameter macro defined in this codebase. To also benchmark the three CPA Lizard parameter macros for comparison (`PARAMS_Classical`, `PARAMS_Recommended`, and `PARAMS_Homadd`), run:

```sh
./scripts/benchmark_ccalizard.sh --all-params
```

Useful quick-test overrides:

```sh
./scripts/benchmark_ccalizard.sh --iter 1 --testnum 1 --runs 1
```

Results are saved under `benchmark-results/`. The script reports whether the host CPU advertises AVX2 support and checks the optimized binary with `objdump` for common AVX/AVX2 integer vector instructions. The optimized build uses `-msse2avx -mavx2 -march=native`, matching the AVX2-oriented options in the Makefile; the source is not a separate hand-written AVX2 implementation.

