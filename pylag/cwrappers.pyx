"""
For speed, several of PyLag's Cython functions take c arrays or pointers as
arguments. Cython does not produce python wrappers for functions
that have arguments with these types. The wrappers provided here are intended
to allow clients to call these functions in isolation.

TODO
----
* Document these wrappers
* Move the wrappers into the modules that contain the functions they wrap, then delete this module entirely.

"""

include "constants.pxi"

import numpy as np

# PyLag data types
from pylag.data_types_python import DTYPE_INT, DTYPE_FLOAT
from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

from libcpp.vector cimport vector

# PyLag cimports
cimport pylag.math as math
cimport pylag.interpolation as interp
from pylag.data_reader cimport DataReader
from pylag.particle_cpp_wrapper cimport ParticleSmartPtr


def get_intersection_point_wrapper(x1, x2, x3, x4, xi):
    cdef DTYPE_FLOAT_t x1_c[2]
    cdef DTYPE_FLOAT_t x2_c[2]
    cdef DTYPE_FLOAT_t x3_c[2]
    cdef DTYPE_FLOAT_t x4_c[2]
    cdef DTYPE_FLOAT_t xi_c[2]
            
    if x1.shape[0] != 2 or x2.shape[0] != 2 or x3.shape[0] != 2 or x4.shape[0] != 2:
        raise ValueError('1D arrays must contain two elements.')
    
    x1_c[:] = x1[:]
    x2_c[:] = x2[:]
    x3_c[:] = x3[:]
    x4_c[:] = x4[:]
    
    math.get_intersection_point(x1_c, x2_c, x3_c, x4_c, xi_c)
    for i in xrange(2):
        xi[i] = xi_c[i]
    return

