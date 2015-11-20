# Cython imports
cimport numpy as np
np.import_array()
from libc.math cimport sqrt as sqrt_c

# Data types used for constructing C data structures
from data_types_python import DTYPE_INT, DTYPE_FLOAT
from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

cdef get_barycentric_coords(DTYPE_FLOAT_t x, DTYPE_FLOAT_t y,
        DTYPE_FLOAT_t[:] x_tri, DTYPE_FLOAT_t[:] y_tri, DTYPE_FLOAT_t[:] phi):

    cdef DTYPE_FLOAT_t a11, a12, a21, a22, det

    # Array elements
    a11 = y_tri[2] - y_tri[0]
    a12 = x_tri[0] - x_tri[2]
    a21 = y_tri[0] - y_tri[1]
    a22 = x_tri[1] - x_tri[0]

    # Determinant
    det = a11 * a22 - a12 * a21

    # Transformation to barycentric coordinates
    phi[0] = (a11*(x - x_tri[0]) + a12*(y - y_tri[0]))/det
    phi[1] = (a21*(x - x_tri[0]) + a22*(y - y_tri[0]))/det
    phi[2] = 1.0 - phi[0] - phi[1]

cdef DTYPE_FLOAT_t shephard_interpolation(DTYPE_FLOAT_t x,
        DTYPE_FLOAT_t y, DTYPE_INT_t npts, DTYPE_FLOAT_t[:] xpts, 
        DTYPE_FLOAT_t[:] ypts, DTYPE_FLOAT_t[:] vals):
    """
    Shepard interpolation.
    """
    # Euclidian distance between the point and a reference point
    cdef DTYPE_FLOAT_t r

    # Weighting applied to a given point
    cdef DTYPE_FLOAT_t w

    # Summed quantities
    cdef DTYPE_FLOAT_t sum
    cdef DTYPE_FLOAT_t sumw

    # Loop index
    cdef DTYPE_INT_t i

    # Loop over all reference points
    sum = 0.0
    sumw = 0.0
    for i in xrange(npts):
        r = get_euclidian_distance(x, y, xpts[i], ypts[i])
        if r == 0.0: return vals[i]
        w = 1.0/(r*r) # TODO hardoced p value of -2.0 for now.
        sum = sum + w
        sumw = sumw + w*vals[i]

    return sumw/sum