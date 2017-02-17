include "constants.pxi"

# Data types used for constructing C data structures
from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

cdef class DataReader:
    cpdef setup_data_access(self, start_datetime, end_datetime)

    cpdef read_data(self, DTYPE_FLOAT_t time) 

    cpdef find_host(self, DTYPE_FLOAT_t xpos_old, DTYPE_FLOAT_t ypos_old,
        DTYPE_FLOAT_t xpos_new, DTYPE_FLOAT_t ypos_new, DTYPE_INT_t guess)

    cpdef get_boundary_intersection(self, DTYPE_FLOAT_t xpos_old,
        DTYPE_FLOAT_t ypos_old, DTYPE_FLOAT_t xpos_new, DTYPE_FLOAT_t ypos_new,
        DTYPE_INT_t last_host)

    cpdef find_zlayer(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
        DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
        DTYPE_INT_t guess)

    cpdef DTYPE_FLOAT_t get_zmin(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
        DTYPE_FLOAT_t ypos, DTYPE_INT_t host)

    cpdef DTYPE_FLOAT_t get_zmax(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
        DTYPE_FLOAT_t ypos, DTYPE_INT_t host)

    cdef get_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_INT_t zlayer, DTYPE_FLOAT_t vel[3])

    cdef get_horizontal_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_INT_t zlayer, DTYPE_FLOAT_t vel[2])

    cdef get_vertical_velocity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos, 
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_INT_t zlayer)

    cpdef get_horizontal_eddy_diffusivity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_INT_t zlayer)

    cpdef get_horizontal_eddy_diffusivity_derivative(self, DTYPE_FLOAT_t time,
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos,
            DTYPE_INT_t host, DTYPE_INT_t zlayer)

    cpdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity(self, DTYPE_FLOAT_t time, DTYPE_FLOAT_t xpos,
            DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos, DTYPE_INT_t host,
            DTYPE_INT_t zlayer) except FLOAT_ERR

    cpdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity_derivative(self, DTYPE_FLOAT_t time,
            DTYPE_FLOAT_t xpos, DTYPE_FLOAT_t ypos, DTYPE_FLOAT_t zpos,
            DTYPE_INT_t host, DTYPE_INT_t zlayer) except FLOAT_ERR
