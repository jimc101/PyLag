"""
This Cython module has the purpose of providing clients with rapid access to 
pseudo random numbers generated by algorithms that form part of the GNU 
Scientific Library (GSL). While Python includes its own module for the
generation of pseudo random numbers (random), calls to it are made through 
Python's API, which is comparatively slow. Using CythonGSL - a set of Cython 
wrappers for GSL - this cost is avoided. Tests indicate using CythonGSL yeilds
a ~ X5 speedup in the generation of normally distributed random deviates when 
compared with calls to Python's random module, which uses the same RNG 
(Mersenne Twister) as invoked here.
"""

cimport cython
from cython_gsl cimport gsl_rng, gsl_rng_alloc, gsl_rng_mt19937, gsl_ran_gaussian

from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

cdef gsl_rng *r = gsl_rng_alloc(gsl_rng_mt19937)

cpdef gauss(DTYPE_FLOAT_t std = 1.0):
    cdef DTYPE_FLOAT_t deviate
    deviate = gsl_ran_gaussian(r, std)
    return deviate

