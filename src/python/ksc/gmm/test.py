import gmm as knossos
import ksc.gmm.gmm as reference
import random
import numpy as np
import math

# Some of these functions are duplicates of those in ksc.mnist.test.
# Currently we can't import that module because we register the same
# C++ generic types in that module too, and there's a conflict.  We
# need to stop doing that, but for now, let's just duplicate.

# Useful functions for creating Knossos vecs
def vd(x): return knossos.vec_double([y for y in x])
def vvd(x): return knossos.vec_vec_double([vd(y) for y in x])

# Shorthand for creating numpy arrays
def ten(x): return np.array(x, dtype=float)

# Useful functions for creating random nested arrays
def r():
    return random.random() * 2 - 1

def rv(n):
    return [r() for _ in range(n)]

def rvv(n, m):
    return [rv(m) for _ in range(n)]

# The ks::vec __iter__ method that is automatically generated by
# pybind11 is one that keeps going off the end of the vec and never
# stops.  Until I get time to dig into how to make it generate a
# better one, here's a handy utility function.
def to_list(x):
    return [x[i] for i in range(len(x))]

def to_list2(x):
    return [to_list(x[i]) for i in range(len(x))]

# Useful functions for checking no NaNs in nested lists
def no_nan(l):
    return all(not math.isnan(x) for x in l)

def no_nan2(l):
    return all(no_nan(x) for x in l)

def main():
    assert_equal_objective()
    print("The assertions didn't throw any errors, so "
          "everything must be good!")

def assert_equal_objective():
    n = 10
    k = 200
    d = 64
    triD = d * (d - 1) // 2

    x      = rvv(n, d)
    alphas = rv(k)
    means  = rvv(k, d)
    qs     = rvv(k, d)
    ls     = rvv(k, triD)

    icf = [q + l for (q, l) in zip(qs, ls)]

    wishart_gamma = 1.0
    wishart_m = 1

    # Check the objectives match
    knossos_objective = knossos.gmm_knossos_gmm_objective(vvd(x),
                                                          vd(alphas),
                                                          vvd(means),
                                                          vvd(qs),
                                                          vvd(ls),
                                                          (wishart_gamma, wishart_m))

    reference_objective =  reference.gmm_objective(ten(alphas),
                                                   ten(means),
                                                   ten(icf),
                                                   ten(x),
                                                   wishart_gamma,
                                                   wishart_m)


    np.testing.assert_almost_equal(knossos_objective,
                                   reference_objective,
                                   decimal=8,
                                   err_msg="Objective")

    print(knossos_objective)
    print(reference_objective)

    # Check no NaNs in reverse mode derivative
    rev = knossos.rev_gmm_knossos_gmm_objective(vvd(x),
                                                vd(alphas),
                                                vvd(means),
                                                vvd(qs),
                                                vvd(ls),
                                                (wishart_gamma, wishart_m),
                                                1.0)

    (d_dx, d_dalphas, d_dmeans, d_dqs, d_dls, (d_dwishart_gamma, d_dwishartm)) = rev

    no_nan_in_rev_result = all([no_nan2(to_list2(d_dx)),
                                no_nan(to_list(d_dalphas)),
                                no_nan2(to_list2(d_dmeans)),
                                no_nan2(to_list2(d_dqs)),
                                no_nan2(to_list2(d_dls)),
                                not math.isnan(d_dwishart_gamma)])

    assert no_nan_in_rev_result

if __name__ == '__main__': main()