"""
Module in which mathematical or physical constants are defined
"""
import numpy as np

from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

# Earth's radius in m
cpdef DTYPE_FLOAT_t earth_radius

# Unit conversions
cpdef DTYPE_FLOAT_t deg_to_radians

# Pi
cpdef DTYPE_FLOAT_t pi
