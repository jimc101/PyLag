from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t
from pylag.data_reader cimport DataReader

cdef class TestHorizBCDataReader(DataReader):
    
    cpdef find_host(self, DTYPE_FLOAT_t xpos_old, DTYPE_FLOAT_t ypos_old,
                    DTYPE_FLOAT_t xpos_new, DTYPE_FLOAT_t ypos_new,
                    DTYPE_INT_t guess):
        return 0, 0

    cpdef find_host_using_local_search(self, DTYPE_FLOAT_t xpos,
                                       DTYPE_FLOAT_t ypos,
                                       DTYPE_INT_t guess):
        return 0, 0

    cpdef find_host_using_global_search(self, DTYPE_FLOAT_t xpos,
                                        DTYPE_FLOAT_t ypos):
        return 0

    cpdef get_boundary_intersection(self, DTYPE_FLOAT_t xpos_old,
                                    DTYPE_FLOAT_t ypos_old,
                                    DTYPE_FLOAT_t xpos_new,
                                    DTYPE_FLOAT_t ypos_new,
                                    DTYPE_INT_t last_host):
        """ Get boundary intersection
        
        Test function assumes the pathline intersected a line with coordinates
        (-1,-1) and (1,1) at the point (0,0). All function arguments are
        ignored.
        
        Consistent choices for testing are:
        xpos_old = 0.0
        ypos_old = -1.0
        xpos_new = 0.0
        ypos_new = 1.0
        host = 0
        """

        return -1.0, -1.0, 1.0, 1.0, 0.0, 0.0
