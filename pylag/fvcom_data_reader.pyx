include "constants.pxi"

import logging

try:
    import configparser
except ImportError:
    import ConfigParser as configparser

import numpy as np

from cpython cimport bool

# Data types used for constructing C data structures
from pylag.data_types_python import DTYPE_INT, DTYPE_FLOAT
from pylag.data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

from libcpp.string cimport string
from libcpp.vector cimport vector

# PyLag cython imports
from particle cimport Particle
from particle_cpp_wrapper cimport to_string
from pylag.data_reader cimport DataReader
from pylag.unstructured cimport UnstructuredGrid
cimport pylag.interpolation as interp
from pylag.math cimport int_min, float_min, get_intersection_point
from pylag.math cimport cartesian_to_sigma_coords, sigma_to_cartesian_coords
from pylag.math cimport Intersection

# PyLag python imports
from pylag import variable_library
from pylag.numerics import get_time_direction

cdef class FVCOMDataReader(DataReader):
    """ DataReader for FVCOM.
    
    Objects of type FVCOMDataReader are intended to manage all access to FVCOM 
    data objects, including data describing the model grid as well as model
    output variables. Provided are methods for searching the model grid for
    host horizontal elements and for interpolating gridded field data to
    a given point in space and time.
    
    Parameters:
    -----------
    config : SafeConfigParser
        Configuration object.
    
    mediator : Mediator
        Mediator object for managing access to data read from file.
    """
    
    # Configurtion object
    cdef object config

    # Mediator for accessing FVCOM model data read in from file
    cdef object mediator

    # Unstructured grid object for performing grid searching etc
    cdef UnstructuredGrid _unstructured_grid

    # List of environmental variables to read and save
    cdef object env_var_names

    # The name of the grid
    cdef string _name

    # Grid dimensions
    cdef DTYPE_INT_t _n_elems, _n_nodes, _n_siglay, _n_siglev
    
    # Element connectivity
    cdef DTYPE_INT_t[:,:] _nv
    
    # Element adjacency
    cdef DTYPE_INT_t[:,:] _nbe
    
    # Nodal coordinates
    cdef DTYPE_FLOAT_t[:] _x
    cdef DTYPE_FLOAT_t[:] _y

    # Element centre coordinates
    cdef DTYPE_FLOAT_t[:] _xc
    cdef DTYPE_FLOAT_t[:] _yc

    # Minimum nodal x/y values
    cdef DTYPE_FLOAT_t _xmin
    cdef DTYPE_FLOAT_t _ymin
    
#    # Interpolation coefficients
#    cdef DTYPE_FLOAT_t[:,:] _a1u
#    cdef DTYPE_FLOAT_t[:,:] _a2u
    
    # Sigma layers and levels
    cdef DTYPE_FLOAT_t[:,:] _siglev
    cdef DTYPE_FLOAT_t[:,:] _siglay
    
    # Bathymetry
    cdef DTYPE_FLOAT_t[:] _h
    
    # Sea surface elevation
    cdef DTYPE_FLOAT_t[:] _zeta_last
    cdef DTYPE_FLOAT_t[:] _zeta_next
    
    # u/v/w velocity components
    cdef DTYPE_FLOAT_t[:,:] _u_last
    cdef DTYPE_FLOAT_t[:,:] _u_next
    cdef DTYPE_FLOAT_t[:,:] _v_last
    cdef DTYPE_FLOAT_t[:,:] _v_next
    cdef DTYPE_FLOAT_t[:,:] _w_last
    cdef DTYPE_FLOAT_t[:,:] _w_next
    
    # Vertical eddy diffusivities
    cdef DTYPE_FLOAT_t[:,:] _kh_last
    cdef DTYPE_FLOAT_t[:,:] _kh_next
    
    # Horizontal eddy viscosities
    cdef DTYPE_FLOAT_t[:,:] _viscofh_last
    cdef DTYPE_FLOAT_t[:,:] _viscofh_next

    # Wet/dry status of elements
    cdef DTYPE_INT_t[:] _wet_cells_last
    cdef DTYPE_INT_t[:] _wet_cells_next

    # Sea water potential temperature
    cdef DTYPE_FLOAT_t[:,:] _thetao_last
    cdef DTYPE_FLOAT_t[:,:] _thetao_next

    # Sea water salinity
    cdef DTYPE_FLOAT_t[:,:] _so_last
    cdef DTYPE_FLOAT_t[:,:] _so_next

    # Time direction
    cdef DTYPE_INT_t _time_direction

    # Time array
    cdef DTYPE_FLOAT_t _time_last
    cdef DTYPE_FLOAT_t _time_next

    # Flags that identify whether a given variable should be read in
    cdef bint _has_Kh, _has_Ah, _has_is_wet

    def __init__(self, config, mediator):
        self.config = config
        self.mediator = mediator

        self._name = b'fvcom'

        # Time direction
        self._time_direction = <int>get_time_direction(config)

        # Set flags from config
        self._has_Kh = self.config.getboolean("OCEAN_CIRCULATION_MODEL", "has_Kh")
        self._has_Ah = self.config.getboolean("OCEAN_CIRCULATION_MODEL", "has_Ah")
        self._has_is_wet = self.config.getboolean("OCEAN_CIRCULATION_MODEL", "has_is_wet")

        # Check to see if any environmental variables are being saved.
        try:
            env_var_names = self.config.get("OUTPUT", "environmental_variables").strip().split(',')
        except (configparser.NoSectionError, configparser.NoOptionError) as e:
            env_var_names = []

        self.env_var_names = []
        for env_var_name in env_var_names:
            env_var_name = env_var_name.strip()
            if env_var_name is not None:
                if env_var_name in variable_library.fvcom_variable_names.keys():
                    self.env_var_names.append(env_var_name)
                else:
                    raise ValueError('Received unsupported variable {}'.format(env_var_name))

        self._read_grid()

        self._read_time_dependent_vars()

    cpdef setup_data_access(self, start_datetime, end_datetime):
        """ Set up access to time-dependent variables.
        
        Parameters:
        -----------
        start_datetime : Datetime
            Datetime object corresponding to the simulation start time.
        
        end_datetime : Datetime
            Datetime object corresponding to the simulation end time.
        """
        self.mediator.setup_data_access(start_datetime, end_datetime)

        self._read_time_dependent_vars()

    cpdef read_data(self, DTYPE_FLOAT_t time):
        """ Read in time dependent variable data from file?
        
        `time' is used to test if new data should be read in from file. If this
        is the case, arrays containing time-dependent variable data are updated.
        
        Parameters:
        -----------
        time : float
            The current time.
        """
        cdef DTYPE_FLOAT_t time_fraction

        time_fraction = interp.get_linear_fraction(time, self._time_last, self._time_next)
        if self._time_direction == 1:
            if time_fraction < 0.0 or time_fraction >= 1.0:
                self.mediator.update_reading_frames(time)
                self._read_time_dependent_vars()
        else:
            if time_fraction <= 0.0 or time_fraction > 1.0:
                self.mediator.update_reading_frames(time)
                self._read_time_dependent_vars()

    cdef DTYPE_INT_t find_host(self, Particle *particle_old,
                               Particle *particle_new) except INT_ERR:
        """ Returns the host horizontal element.
        
        This function first tries to find the new host horizontal element using
        a local search algorithm based on the new point's barycentric
        coordinates. This is relatively fast. However, it can incorrectly flag
        that a particle has left the domain when in-fact it hasn't. For this
        reason, when the local host element search indicates that a particle
        has left the domain, a check is performed based on the particle's
        pathline - if this crosses a known boundary, the particle is deemed
        to have left the domain.

        The function returns a flag that indicates whether or not the particle
        has been found within the domain. If it has, it's host element will 
        have been set appropriately. If not, the the new particle's host
        element will have been set to the last host element the particle passed
        through before exiting the domain.
        
        Conventions
        -----------
        flag = IN_DOMAIN:
            This indicates that the particle was found successfully. Host is the
            index of the new host element.
        
        flag = LAND_BDY_CROSSED:
            This indicates that the particle exited the domain across a land
            boundary. Host is set to the last element the particle passed
            through before exiting the domain.

        flag = OPEN_BDY_CROSSED:
            This indicates that the particle exited the domain across an open
            boundary. Host is set to the last element the particle passed
            through before exiting the domain.
        
        Parameters:
        -----------       
        particle_old: *Particle
            The particle at its old position.

        particle_new: *Particle
            The particle at its new position. The host element will be updated.
        
        Returns:
        --------
        flag : int
            Integer flag that indicates whether or not the seach was successful.
        """
        cdef DTYPE_INT_t flag, host
        
        flag = self._unstructured_grid.find_host_using_local_search(particle_new,
                                                                    particle_old.get_host_horizontal_elem())

        if flag != IN_DOMAIN:
            # Local search failed to find the particle. Perform check to see if
            # the particle has indeed left the model domain
            flag = self._unstructured_grid.find_host_using_particle_tracing(particle_old,
                                                                            particle_new)

        return flag

    cdef DTYPE_INT_t find_host_using_local_search(self, Particle *particle,
                                                  DTYPE_INT_t first_guess) except INT_ERR:
        """ Returns the host horizontal element through local searching.

        This function is a wrapper for the same function implemented in UnstructuredGrid.

        Parameters:
        -----------
        particle: *Particle
            The particle.

        DTYPE_INT_t: first_guess
            The first element to start searching.

        Returns:
        --------
        flag : int
            Integer flag that indicates whether or not the seach was successful.
        """
        return self._unstructured_grid.find_host_using_local_search(particle, first_guess)

    cdef DTYPE_INT_t find_host_using_global_search(self, Particle *particle) except INT_ERR:
        """ Returns the host horizontal element through global searching.

        This function is a wrapper for the same function implemented in UnstructuredGrid.

        Parameters:
        -----------
        particle_old: *Particle
            The particle.

        Returns:
        --------
        flag : int
            Integer flag that indicates whether or not the seach was successful.
        """
        return self._unstructured_grid.find_host_using_global_search(particle)

    cdef Intersection get_boundary_intersection(self, Particle *particle_old, Particle *particle_new):
        """ Find the boundary intersection point

        This function is a wrapper for the same function implemented in UnstructuredGrid.

        Parameters:
        -----------
        particle_old: *Particle
            The particle at its old position.

        particle_new: *Particle
            The particle at its new position.

        Returns:
        --------
        intersection: Intersection
            Object describing the boundary intersection.
        """
        return self._unstructured_grid.get_boundary_intersection(particle_old, particle_new)

    cdef set_default_location(self, Particle *particle):
        """ Set default location

        Move the particle to its host element's centroid.
        """
        self._unstructured_grid.set_default_location(particle)

        return

    cdef set_local_coordinates(self, Particle *particle):
        """ Set local coordinates

        This function is a wrapper for the same function implemented in UnstructuredGrid.

        Parameters:
        -----------
        particle: *Particle
            Pointer to a Particle struct
        """
        self._unstructured_grid.set_local_coordinates(particle)

        return

    cdef DTYPE_INT_t set_vertical_grid_vars(self, DTYPE_FLOAT_t time,
                                            Particle *particle) except INT_ERR:
        """ Find the host depth layer
        
        Find the depth layer containing x3. In FVCOM, Sigma levels are counted
        up from 0 starting at the surface, where sigma = 0, and moving downwards
        to the sea floor where sigma = -1. The current sigma layer is
        found by determining the two sigma levels that bound the given z
        position.
        """
        cdef DTYPE_FLOAT_t sigma, sigma_upper_level, sigma_lower_level
        
        cdef DTYPE_FLOAT_t sigma_test, sigma_upper_layer, sigma_lower_layer

        cdef DTYPE_FLOAT_t h, zeta

        cdef DTYPE_INT_t k

        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        cdef vector[DTYPE_FLOAT_t] phi = particle.get_phi()

        # Compute sigma
        h = self.get_zmin(time, particle)
        zeta = self.get_zmax(time, particle)
        sigma = cartesian_to_sigma_coords(particle.get_x3(), h, zeta)

        # Loop over all levels to find the host z layer
        sigma_lower_level = self._interp_on_sigma_level(phi, host_element, 0)
        for k in xrange(self._n_siglay):
            sigma_upper_level = sigma_lower_level
            sigma_lower_level = self._interp_on_sigma_level(phi, host_element, k+1)

            if sigma <= sigma_upper_level and sigma >= sigma_lower_level:
                # Host layer found
                particle.set_k_layer(k)

                # Set the sigma level interpolation coefficient
                particle.set_omega_interfaces(interp.get_linear_fraction(sigma, sigma_lower_level, sigma_upper_level))

                # Set variables describing which half of the sigma layer the
                # particle sits in and whether or not it resides in a boundary
                # layer
                sigma_test = self._interp_on_sigma_layer(phi, host_element, k)

                # Is x3 in the top or bottom boundary layer?
                if (k == 0 and sigma >= sigma_test) or (k == self._n_siglay - 1 and sigma <= sigma_test):
                        particle.set_in_vertical_boundary_layer(True)
                        return IN_DOMAIN

                # x3 bounded by upper and lower sigma layers
                particle.set_in_vertical_boundary_layer(False)
                if sigma >= sigma_test:
                    particle.set_k_upper_layer(k - 1)
                    particle.set_k_lower_layer(k)
                else:
                    particle.set_k_upper_layer(k)
                    particle.set_k_lower_layer(k + 1)

                # Set the sigma layer interpolation coefficient
                sigma_lower_layer = self._interp_on_sigma_layer(phi, host_element, particle.get_k_lower_layer())
                sigma_upper_layer = self._interp_on_sigma_layer(phi, host_element, particle.get_k_upper_layer())
                particle.set_omega_layers(interp.get_linear_fraction(sigma, sigma_lower_layer, sigma_upper_layer))

                return IN_DOMAIN

        return BDY_ERROR

    cpdef DTYPE_FLOAT_t get_xmin(self) except FLOAT_ERR:
        return self._xmin

    cpdef DTYPE_FLOAT_t get_ymin(self) except FLOAT_ERR:
        return self._ymin

    cdef DTYPE_FLOAT_t get_zmin(self, DTYPE_FLOAT_t time, Particle *particle) except FLOAT_ERR:
        """ Returns the bottom depth in cartesian coordinates

        h is defined at element nodes. Linear interpolation in space is used
        to compute h(x,y). NB the negative of h (which is +ve downwards) is
        returned.

        Parameters:
        -----------
        time : float
            Time.

        particle: *Particle
            Pointer to a Particle object.

        Returns:
        --------
        zmin : float
            The bottom depth.
        """
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier  
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()
        cdef vector[DTYPE_FLOAT_t] h_tri = vector[DTYPE_FLOAT_t](N_VERTICES, -999.) # Bathymetry at nodes
        cdef DTYPE_FLOAT_t h # Bathymetry at (x1, x2)

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host_element]
            h_tri[i] = self._h[vertex]

        h = interp.interpolate_within_element(h_tri, particle.get_phi())

        return -h

    cdef DTYPE_FLOAT_t get_zmax(self, DTYPE_FLOAT_t time, Particle *particle) except FLOAT_ERR:
        """ Returns the sea surface height in cartesian coordinates

        zeta is defined at element nodes. Interpolation proceeds through linear
        interpolation time followed by interpolation in space.

        Parameters:
        -----------
        time : float
            Time.

        particle: *Particle
            Pointer to a Particle object.
        
        Returns:
        --------
        zmax : float
            Sea surface elevation.
        """
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier
        cdef DTYPE_FLOAT_t time_fraction # Time interpolation
        cdef DTYPE_FLOAT_t zeta # Sea surface elevation at (t, x1, x2)
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        # Intermediate arrays
        cdef vector[DTYPE_FLOAT_t] zeta_tri_t_last = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] zeta_tri_t_next = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] zeta_tri = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host_element]
            zeta_tri_t_last[i] = self._zeta_last[vertex]
            zeta_tri_t_next[i] = self._zeta_next[vertex]

        # Interpolate in time
        time_fraction = interp.get_linear_fraction_safe(time, self._time_last, self._time_next)
        for i in xrange(N_VERTICES):
            zeta_tri[i] = interp.linear_interp(time_fraction, zeta_tri_t_last[i], zeta_tri_t_next[i])

        # Interpolate in space
        zeta = interp.interpolate_within_element(zeta_tri, particle.get_phi())

        return zeta

    cdef get_velocity(self, DTYPE_FLOAT_t time, Particle* particle,
            DTYPE_FLOAT_t vel[3]):
        """ Returns the velocity u(t,x,y,z) through linear interpolation
        
        Returns the velocity u(t,x,y,z) through interpolation for a particle.

        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object.

        Return:
        -------
        vel : C array, float
            u/v/w velocity components stored in a C array.           
        """
        # Compute u/v velocities and save
        self._get_velocity_using_shepard_interpolation(time, particle, vel)
        return

    cdef DTYPE_FLOAT_t get_environmental_variable(self, var_name,
            DTYPE_FLOAT_t time, Particle *particle) except FLOAT_ERR:
        """ Returns the value of the given environmental variable through linear interpolation

        In FVCOM, active and passive tracers are defined at element nodes on sigma layers,
        which is the same as viscofh. Above and below the top and bottom sigma layers respectively
        values for the specified variable are extrapolated, taking a value equal to that at the layer
        centre. Linear interpolation in the vertical is used for z positions lying between the top
        and bottom sigma layers.

        NB - All the hard work is farmed out to a private function, which both this function and the
        function for computing viscofh use.

        Support for extracting the following FVCOM environmental variables has been implemented:

        thetao - Sea water potential temperature

        so - Sea water salinty

        Parameters:
        -----------
        var_name : str
            The name of the variable. See above for a list of supported options.

        time : float
            Time at which to interpolate.

        particle: *Particle
            Pointer to a Particle object.

        Returns:
        --------
        var : float
            The interpolated value of the variable at the specified point in time and space.
        """
        cdef DTYPE_FLOAT_t var # Environmental variable at (t, x1, x2, x3)

        if var_name in self.env_var_names:
            if var_name == 'thetao':
                var = self._get_variable(self._thetao_last, self._thetao_next, time, particle)
            elif var_name == 'so':
                var = self._get_variable(self._so_last, self._so_next, time, particle)
            return var
        else:
            raise ValueError("Invalid variable name `{}'".format(var_name))

    cdef get_horizontal_eddy_viscosity(self, DTYPE_FLOAT_t time,
            Particle* particle):
        """ Returns the horizontal eddy viscosity through linear interpolation

        viscofh is defined at element nodes on sigma layers. Above and below the
        top and bottom sigma layers respectively viscofh is extrapolated, taking
        a value equal to that at the layer centre. Linear interpolation in the vertical
        is used for z positions lying between the top and bottom sigma layers.

        This function is effectively a wrapper for the private method `_get_variable'.

        Parameters:
        -----------
        time : float
            Time at which to interpolate.

        particle: *Particle
            Pointer to a Particle object.

        Returns:
        --------
        viscofh : float
            The interpolated value of the horizontal eddy viscosity at the specified point in time and space.
        """
        cdef DTYPE_FLOAT_t var # viscofh at (t, x1, x2, x3)

        var = self._get_variable(self._viscofh_last, self._viscofh_next, time, particle)

        return var

    cdef get_horizontal_eddy_viscosity_derivative(self, DTYPE_FLOAT_t time,
            Particle* particle, DTYPE_FLOAT_t Ah_prime[2]):
        """ Returns the gradient in the horizontal eddy viscosity
        
        The gradient is first computed on sigma layers bounding the particle's
        position, or simply on the nearest layer if the particle lies above or
        below the top or bottom sigma layers respectively. Linear interpolation
        in the vertical is used for z positions lying between the top and bottom
        sigma layers.
        
        Within an element, the gradient itself is calculated from the gradient 
        in the element's barycentric coordinates `phi' through linear
        interpolation (e.g. Lynch et al 2015, p. 238) 
        
        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object.

        Ah_prime : C array, float
            dAh_dx and dH_dy components stored in a C array of length two.  

        References:
        -----------
        Lynch, D. R. et al (2014). Particles in the coastal ocean: theory and
        applications. Cambridge: Cambridge University Press.
        doi.org/10.1017/CBO9781107449336
        """
        # No. of vertices and a temporary object used for determining variable
        # values at the host element's nodes
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier

        # Variables used in interpolation in time      
        cdef DTYPE_FLOAT_t time_fraction

        # Gradients in phi
        cdef vector[DTYPE_FLOAT_t] dphi_dx = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] dphi_dy = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)

        # Intermediate arrays - viscofh
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_t_last_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_t_next_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_t_last_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_t_next_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] viscofh_tri_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        
        # Particle k_layer
        cdef DTYPE_INT_t k_layer = particle.get_k_layer()
        cdef DTYPE_INT_t k_lower_layer = particle.get_k_lower_layer()
        cdef DTYPE_INT_t k_upper_layer = particle.get_k_upper_layer()
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        # Gradients on lower and upper bounding sigma layers
        cdef DTYPE_FLOAT_t dviscofh_dx_layer_1
        cdef DTYPE_FLOAT_t dviscofh_dy_layer_1
        cdef DTYPE_FLOAT_t dviscofh_dx_layer_2
        cdef DTYPE_FLOAT_t dviscofh_dy_layer_2
        
        # Gradient 
        cdef DTYPE_FLOAT_t dviscofh_dx
        cdef DTYPE_FLOAT_t dviscofh_dy

        # Time fraction
        time_fraction = interp.get_linear_fraction_safe(time, self._time_last, self._time_next)

        # Get gradient in phi
        self._unstructured_grid.get_grad_phi(host_element, dphi_dx, dphi_dy)

        # No vertical interpolation for particles near to the surface or bottom, 
        # i.e. above or below the top or bottom sigma layer depths respectively.
        if particle.get_in_vertical_boundary_layer() is True:
            # Extract viscofh near to the boundary
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host_element]
                viscofh_tri_t_last_layer_1[i] = self._viscofh_last[k_layer, vertex]
                viscofh_tri_t_next_layer_1[i] = self._viscofh_next[k_layer, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                viscofh_tri_layer_1[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_1[i],
                                            viscofh_tri_t_next_layer_1[i])

            # Interpolate d{}/dx and d{}/dy within the host element
            Ah_prime[0] = interp.interpolate_within_element(viscofh_tri_layer_1, dphi_dx)
            Ah_prime[1] = interp.interpolate_within_element(viscofh_tri_layer_1, dphi_dy)
            return
        else:
            # Extract viscofh on the lower and upper bounding sigma layers
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host_element]
                viscofh_tri_t_last_layer_1[i] = self._viscofh_last[k_lower_layer, vertex]
                viscofh_tri_t_next_layer_1[i] = self._viscofh_next[k_lower_layer, vertex]
                viscofh_tri_t_last_layer_2[i] = self._viscofh_last[k_upper_layer, vertex]
                viscofh_tri_t_next_layer_2[i] = self._viscofh_next[k_upper_layer, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                viscofh_tri_layer_1[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_1[i],
                                            viscofh_tri_t_next_layer_1[i])
                viscofh_tri_layer_2[i] = interp.linear_interp(time_fraction, 
                                            viscofh_tri_t_last_layer_2[i],
                                            viscofh_tri_t_next_layer_2[i])

            # Interpolate d{}/dx and d{}/dy within the host element on the upper
            # and lower bounding sigma layers
            dviscofh_dx_layer_1 = interp.interpolate_within_element(viscofh_tri_layer_1, dphi_dx)
            dviscofh_dy_layer_1 = interp.interpolate_within_element(viscofh_tri_layer_1, dphi_dy)
            dviscofh_dx_layer_2 = interp.interpolate_within_element(viscofh_tri_layer_2, dphi_dx)
            dviscofh_dy_layer_2 = interp.interpolate_within_element(viscofh_tri_layer_2, dphi_dy)

            # Interpolate d{}/dx and d{}/dy between bounding sigma layers and
            # save in the array Ah_prime
            Ah_prime[0] = interp.linear_interp(particle.get_omega_layers(), dviscofh_dx_layer_1, dviscofh_dx_layer_2)
            Ah_prime[1] = interp.linear_interp(particle.get_omega_layers(), dviscofh_dy_layer_1, dviscofh_dy_layer_2)

    cdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity(self, DTYPE_FLOAT_t time,
            Particle* particle) except FLOAT_ERR:
        """ Returns the vertical eddy diffusivity through linear interpolation.
        
        The vertical eddy diffusivity is defined at element nodes on sigma
        levels. Interpolation is performed first in time, then in x and y,
        and finally in z.
        
        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object.
        
        Returns:
        --------
        kh : float
            The vertical eddy diffusivity.        
        
        """
        # Particle k_layer
        cdef DTYPE_INT_t k_layer = particle.get_k_layer()

        # Interpolated diffusivities on lower and upper bounding sigma levels
        cdef DTYPE_FLOAT_t kh_lower_level
        cdef DTYPE_FLOAT_t kh_upper_level
        
        # NB The index corresponding to the layer the particle presently resides
        # in is used to calculate the index of the under and over lying k levels 
        kh_lower_level = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+1)
        kh_upper_level = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer)

        return interp.linear_interp(particle.get_omega_interfaces(), kh_lower_level, kh_upper_level)


    cdef DTYPE_FLOAT_t get_vertical_eddy_diffusivity_derivative(self,
            DTYPE_FLOAT_t time, Particle* particle) except FLOAT_ERR:
        """ Returns the gradient in the vertical eddy diffusivity.
        
        Return a numerical approximation of the gradient in the vertical eddy 
        diffusivity at (t,x,y,z) using central differencing. First, the
        diffusivity is computed on the sigma levels bounding the particle.
        Central differencing is then used to compute the gradient in the
        diffusivity on these levels. Finally, the gradient in the diffusivity
        is interpolated to the particle's exact position. This algorithm
        mirrors that used in GOTMDataReader, which is why it has been implemented
        here. However, in contrast to GOTMDataReader, which calculates the
        gradient in the diffusivity at all levels once each simulation time step,
        resulting in significant time savings, this function is exectued once
        for each particle. It is thus quite costly! To make things worse, the 
        code, as implemented here, is highly repetitive, and no doubt efficiency
        savings could be found. 

        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object.
        
        Returns:
        --------
        k_prime : float
            Gradient in the vertical eddy diffusivity field.
        """
        cdef DTYPE_FLOAT_t kh_0, kh_1, kh_2, kh_3
        cdef DTYPE_FLOAT_t sigma_0, sigma_1, sigma_2, sigma_3
        cdef DTYPE_FLOAT_t z_0, z_1, z_2, z_3
        cdef DTYPE_FLOAT_t dkh_lower_level, dkh_upper_level
        cdef DTYPE_FLOAT_t h, zeta

        # Particle k_layer
        cdef DTYPE_INT_t k_layer = particle.get_k_layer()
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        cdef vector[DTYPE_FLOAT_t] phi = particle.get_phi()

        h = self.get_zmin(time, particle)
        zeta = self.get_zmax(time, particle)

        if k_layer == 0:
            kh_0 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer)
            sigma_0 = self._interp_on_sigma_level(phi, host_element, k_layer)

            kh_1 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+1)
            sigma_1 = self._interp_on_sigma_level(phi, host_element, k_layer+1)

            kh_2 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+2)
            sigma_2 = self._interp_on_sigma_level(phi, host_element, k_layer+2)

            # Convert to cartesian coordinates
            z_0 = sigma_to_cartesian_coords(sigma_0, h, zeta)
            z_1 = sigma_to_cartesian_coords(sigma_1, h, zeta)
            z_2 = sigma_to_cartesian_coords(sigma_2, h, zeta)

            dkh_lower_level = (kh_0 - kh_2) / (z_0 - z_2)
            dkh_upper_level = (kh_0 - kh_1) / (z_0 - z_1)
            
        elif k_layer == self._n_siglay - 1:
            kh_0 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer-1)
            sigma_0 = self._interp_on_sigma_level(phi, host_element, k_layer-1)

            kh_1 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer)
            sigma_1 = self._interp_on_sigma_level(phi, host_element, k_layer)

            kh_2 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+1)
            sigma_2 = self._interp_on_sigma_level(phi, host_element, k_layer+1)

            # Convert to cartesian coordinates
            z_0 = sigma_to_cartesian_coords(sigma_0, h, zeta)
            z_1 = sigma_to_cartesian_coords(sigma_1, h, zeta)
            z_2 = sigma_to_cartesian_coords(sigma_2, h, zeta)

            dkh_lower_level = (kh_1 - kh_2) / (z_1 - z_2)
            dkh_upper_level = (kh_0 - kh_2) / (z_0 - z_2)
            
        else:
            kh_0 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer-1)
            sigma_0 = self._interp_on_sigma_level(phi, host_element, k_layer-1)

            kh_1 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer)
            sigma_1 = self._interp_on_sigma_level(phi, host_element, k_layer)

            kh_2 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+1)
            sigma_2 = self._interp_on_sigma_level(phi, host_element, k_layer+1)

            kh_3 = self._get_vertical_eddy_diffusivity_on_level(time, particle, k_layer+2)
            sigma_3 = self._interp_on_sigma_level(phi, host_element, k_layer+2)

            # Convert to cartesian coordinates
            z_0 = sigma_to_cartesian_coords(sigma_0, h, zeta)
            z_1 = sigma_to_cartesian_coords(sigma_1, h, zeta)
            z_2 = sigma_to_cartesian_coords(sigma_2, h, zeta)
            z_3 = sigma_to_cartesian_coords(sigma_3, h, zeta)

            dkh_lower_level = (kh_1 - kh_3) / (z_1 - z_3)
            dkh_upper_level = (kh_0 - kh_2) / (z_0 - z_2)
            
        return interp.linear_interp(particle.get_omega_interfaces(), dkh_lower_level, dkh_upper_level)

    cdef DTYPE_INT_t is_wet(self, DTYPE_FLOAT_t time, Particle *particle) except INT_ERR:
        """ Return an integer indicating whether `host' is wet or dry
        
        The function returns 1 if `host' is wet at time `time' and 
        0 if `host' is dry.
        
        The wet-dry distinction reflects two discrete states - either the
        element is wet, or it is dry. This raises the question of how to deal
        with intermediate times, such that td < t < tw where
        t is the current model time, and td and tw are conescutive input time
        points between which the host element switches from being dry to being
        wet. The approach taken is conservative, and involves flagging the
        element as being dry if either one or both of the input time points
        bounding the current model time indicate that the element is dry. In this
        simple procedure, the `time' parameter is actually unused.
        
        NB - just because an element is flagged as being dry does not mean
        that particles are necessarily frozen. Clients can still try to advect
        particles within such elements, and the interpolated velocity field may
        yield non-zero values, depending on the state of the host and
        surrounding elements in the given time window.
        
        Parameters:
        -----------
        time : float
            Time (unused)

        host : int
            Integer that identifies the host element in question
        """
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        if self._has_is_wet:
            if self._wet_cells_last[host_element] == 0 or self._wet_cells_next[host_element] == 0:
                return 0
        return 1
        
    cdef _get_variable(self, DTYPE_FLOAT_t[:, :] var_last, DTYPE_FLOAT_t[:, :] var_next,
            DTYPE_FLOAT_t time, Particle* particle):
        """ Returns the value of the variable through linear interpolation

        Private method for interpolating fields specified at element nodes on sigma layers.
        This is the case for both viscofh and active and passive tracers. Above and below the
        top and bottom sigma layers respectively values are extrapolated, taking
        a value equal to that at the layer centre. Linear interpolation in the vertical
        is used for z positions lying between the top and bottom sigma layers.
        
        Parameters:
        -----------
        var_last : 2D MemoryView
            Array of variable values at the last time index.

        var_next : 2D MemoryView
            Array of variable values at the next time index.

        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object. 
        
        Returns:
        --------
        var : float
            The interpolated value of the variable at the specified point in time and space.
        """
        # No. of vertices and a temporary object used for determining variable
        # values at the host element's nodes
        cdef int i # Loop counters
        cdef int vertex # Vertex identifier

        # Variables used in interpolation in time      
        cdef DTYPE_FLOAT_t time_fraction
        
        # Intermediate arrays - var
        cdef vector[DTYPE_FLOAT_t] var_tri_t_last_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] var_tri_t_next_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] var_tri_t_last_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] var_tri_t_next_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] var_tri_layer_1 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] var_tri_layer_2 = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        
        # Interpolated values on lower and upper bounding sigma layers
        cdef DTYPE_FLOAT_t var_layer_1
        cdef DTYPE_FLOAT_t var_layer_2

        # Particle k layers
        cdef DTYPE_INT_t k_layer = particle.get_k_layer()
        cdef DTYPE_INT_t k_lower_layer = particle.get_k_lower_layer()
        cdef DTYPE_INT_t k_upper_layer = particle.get_k_upper_layer()
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        # Local coordinates
        cdef vector[DTYPE_FLOAT_t] phi = particle.get_phi()

        # Time fraction
        time_fraction = interp.get_linear_fraction_safe(time, self._time_last, self._time_next)

        # No vertical interpolation for particles near to the surface or bottom, 
        # i.e. above or below the top or bottom sigma layer depths respectively.
        if particle.get_in_vertical_boundary_layer() is True:
            # Extract values near to the boundary
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host_element]
                var_tri_t_last_layer_1[i] = var_last[k_layer, vertex]
                var_tri_t_next_layer_1[i] = var_next[k_layer, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                var_tri_layer_1[i] = interp.linear_interp(time_fraction,
                                            var_tri_t_last_layer_1[i],
                                            var_tri_t_next_layer_1[i])

            # Interpolate var within the host element
            return interp.interpolate_within_element(var_tri_layer_1, phi)

        else:
            # Extract var on the lower and upper bounding sigma layers
            for i in xrange(N_VERTICES):
                vertex = self._nv[i,host_element]
                var_tri_t_last_layer_1[i] = var_last[k_lower_layer, vertex]
                var_tri_t_next_layer_1[i] = var_next[k_lower_layer, vertex]
                var_tri_t_last_layer_2[i] = var_last[k_upper_layer, vertex]
                var_tri_t_next_layer_2[i] = var_next[k_upper_layer, vertex]

            # Interpolate in time
            for i in xrange(N_VERTICES):
                var_tri_layer_1[i] = interp.linear_interp(time_fraction,
                                            var_tri_t_last_layer_1[i],
                                            var_tri_t_next_layer_1[i])
                var_tri_layer_2[i] = interp.linear_interp(time_fraction,
                                            var_tri_t_last_layer_2[i],
                                            var_tri_t_next_layer_2[i])

            # Interpolate var within the host element on the upper and lower
            # bounding sigma layers
            var_layer_1 = interp.interpolate_within_element(var_tri_layer_1, phi)
            var_layer_2 = interp.interpolate_within_element(var_tri_layer_2, phi)

            return interp.linear_interp(particle.get_omega_layers(), var_layer_1, var_layer_2)

    cdef DTYPE_FLOAT_t _get_vertical_eddy_diffusivity_on_level(self,
            DTYPE_FLOAT_t time, Particle* particle,
            DTYPE_INT_t k_level) except FLOAT_ERR:
        """ Returns the vertical eddy diffusivity on a level
        
        The vertical eddy diffusivity is defined at element nodes on sigma
        levels. Interpolation is performed first in time, then in x and y to
        give the eddy diffusivity on the specified depth level.
        
        For internal use only.
        
        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle : *Particle
            Pointer to a Particle object.
        
        k_level : int
            The dpeth level on which to interpolate.
        
        Returns:
        --------
        kh : float
            The vertical eddy diffusivity at the particle's position on the
            specified level.
        
        """
        # Loop counter
        cdef int i
        
        # Vertex identifier
        cdef int vertex

        # Host element
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        # Time fraction used for interpolation in time        
        cdef DTYPE_FLOAT_t time_fraction

        # Intermediate arrays - kh
        cdef vector[DTYPE_FLOAT_t] kh_tri_t_last = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] kh_tri_t_next = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef vector[DTYPE_FLOAT_t] kh_tri = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        
        # Interpolated diffusivities on the specified level
        cdef DTYPE_FLOAT_t kh

        # Extract kh on the lower and upper bounding sigma levels, h and zeta
        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host_element]
            kh_tri_t_last[i] = self._kh_last[k_level, vertex]
            kh_tri_t_next[i] = self._kh_next[k_level, vertex]

        # Interpolate kh and zeta in time
        time_fraction = interp.get_linear_fraction_safe(time, self._time_last, self._time_next)
        for i in xrange(N_VERTICES):
            kh_tri[i] = interp.linear_interp(time_fraction, kh_tri_t_last[i], kh_tri_t_next[i])

        # Interpolate kh, zeta and h within the host
        kh = interp.interpolate_within_element(kh_tri, particle.get_phi())

        return kh

    cdef _get_velocity_using_shepard_interpolation(self, DTYPE_FLOAT_t time,
            Particle* particle, DTYPE_FLOAT_t vel[3]):
        """ Return (u,v,w) velocities at a point using Shepard interpolation
        
        In FVCOM, the u, v, and w velocity components are defined at element
        centres on sigma layers and saved at discrete points in time. Here,
        u(t,x,y,z), v(t,x,y,z) and w(t,x,y,z) are retrieved through i) linear
        interpolation in t and z, and ii) Shepard interpolation (which is
        basically a special case of normalized radial basis function
        interpolation) in x and y.

        In Shepard interpolation, the algorithm uses velocities defined at 
        the host element's centre and its immediate neghbours (i.e. at the
        centre of those elements that share a face with the host element).
        
        NB - this function returns the vertical velocity in z coordinate space
        (units m/s) and not the vertical velocity in sigma coordinate space.
        
        Parameters:
        -----------
        time : float
            Time at which to interpolate.
        
        particle: *Particle
            Pointer to a Particle object.
        
        Returns:
        --------
        vel : C array, float
            Three element array giving the u, v and w velocity components.
        """
        # x/y coordinates of element centres
        cdef vector[DTYPE_FLOAT_t] xc = vector[DTYPE_FLOAT_t](4, -999.)
        cdef vector[DTYPE_FLOAT_t] yc = vector[DTYPE_FLOAT_t](4, -999.)

        # Vel at element centres in overlying sigma layer
        cdef vector[DTYPE_FLOAT_t] uc1 = vector[DTYPE_FLOAT_t](4, -999.)
        cdef vector[DTYPE_FLOAT_t] vc1 = vector[DTYPE_FLOAT_t](4, -999.)
        cdef vector[DTYPE_FLOAT_t] wc1 = vector[DTYPE_FLOAT_t](4, -999.)

        # Vel at element centres in underlying sigma layer
        cdef vector[DTYPE_FLOAT_t] uc2 = vector[DTYPE_FLOAT_t](4, -999.)
        cdef vector[DTYPE_FLOAT_t] vc2 = vector[DTYPE_FLOAT_t](4, -999.)
        cdef vector[DTYPE_FLOAT_t] wc2 = vector[DTYPE_FLOAT_t](4, -999.)
        
        # Particle k layers
        cdef DTYPE_INT_t k_layer = particle.get_k_layer()
        cdef DTYPE_INT_t k_lower_layer = particle.get_k_lower_layer()
        cdef DTYPE_INT_t k_upper_layer = particle.get_k_upper_layer()
        cdef DTYPE_INT_t host_element = particle.get_host_horizontal_elem()

        # Vel at the given location in the overlying sigma layer
        cdef DTYPE_FLOAT_t up1, vp1, wp1
        
        # Vel at the given location in the underlying sigma layer
        cdef DTYPE_FLOAT_t up2, vp2, wp2
         
        # Variables used in interpolation in time      
        cdef DTYPE_FLOAT_t time_fraction

        # Array and loop indices
        cdef DTYPE_INT_t i, neighbour
        
        cdef DTYPE_INT_t nbe_min

        # Time fraction
        time_fraction = interp.get_linear_fraction_safe(time, self._time_last, self._time_next)

        if particle.get_in_vertical_boundary_layer() is True:
            xc[0] = self._xc[host_element]
            yc[0] = self._yc[host_element]
            uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_layer, host_element], self._u_next[k_layer, host_element])
            vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_layer, host_element], self._v_next[k_layer, host_element])
            wc1[0] = interp.linear_interp(time_fraction, self._w_last[k_layer, host_element], self._w_next[k_layer, host_element])
            for i in xrange(3):
                neighbour = self._nbe[i, host_element]
                if neighbour >= 0:
                    xc[i+1] = self._xc[neighbour]
                    yc[i+1] = self._yc[neighbour]
                    uc1[i+1] = interp.linear_interp(time_fraction, self._u_last[k_layer, neighbour], self._u_next[k_layer, neighbour])
                    vc1[i+1] = interp.linear_interp(time_fraction, self._v_last[k_layer, neighbour], self._v_next[k_layer, neighbour])
                    wc1[i+1] = interp.linear_interp(time_fraction, self._w_last[k_layer, neighbour], self._w_next[k_layer, neighbour])

            vel[0] = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, uc1)
            vel[1] = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, vc1)
            vel[2] = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, wc1)
            return  
        else:
            xc[0] = self._xc[host_element]
            yc[0] = self._yc[host_element]
            uc1[0] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, host_element], self._u_next[k_lower_layer, host_element])
            vc1[0] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, host_element], self._v_next[k_lower_layer, host_element])
            wc1[0] = interp.linear_interp(time_fraction, self._w_last[k_lower_layer, host_element], self._w_next[k_lower_layer, host_element])
            uc2[0] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, host_element], self._u_next[k_upper_layer, host_element])
            vc2[0] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, host_element], self._v_next[k_upper_layer, host_element])
            wc2[0] = interp.linear_interp(time_fraction, self._w_last[k_upper_layer, host_element], self._w_next[k_upper_layer, host_element])
            for i in xrange(3):
                neighbour = self._nbe[i, host_element]
                if neighbour >= 0:
                    xc[i+1] = self._xc[neighbour]
                    yc[i+1] = self._yc[neighbour]
                    uc1[i+1] = interp.linear_interp(time_fraction, self._u_last[k_lower_layer, neighbour], self._u_next[k_lower_layer, neighbour])
                    vc1[i+1] = interp.linear_interp(time_fraction, self._v_last[k_lower_layer, neighbour], self._v_next[k_lower_layer, neighbour])
                    wc1[i+1] = interp.linear_interp(time_fraction, self._w_last[k_lower_layer, neighbour], self._w_next[k_lower_layer, neighbour])
                    uc2[i+1] = interp.linear_interp(time_fraction, self._u_last[k_upper_layer, neighbour], self._u_next[k_upper_layer, neighbour])
                    vc2[i+1] = interp.linear_interp(time_fraction, self._v_last[k_upper_layer, neighbour], self._v_next[k_upper_layer, neighbour])
                    wc2[i+1] = interp.linear_interp(time_fraction, self._w_last[k_upper_layer, neighbour], self._w_next[k_upper_layer, neighbour])

        # ... lower bounding sigma layer
        up1 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, uc1)
        vp1 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, vc1)
        wp1 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, wc1)

        # ... upper bounding sigma layer
        up2 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, uc2)
        vp2 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, vc2)
        wp2 = interp.shepard_interpolation(particle.get_x1(), particle.get_x2(), xc, yc, wc2)

        # Vertical interpolation
        vel[0] = interp.linear_interp(particle.get_omega_layers(), up1, up2)
        vel[1] = interp.linear_interp(particle.get_omega_layers(), vp1, vp2)
        vel[2] = interp.linear_interp(particle.get_omega_layers(), wp1, wp2)
        return

    def _read_grid(self):
        """ Set grid and coordinate variables.
        
        All communications go via the mediator in order to guarantee support for
        both serial and parallel simulations.
        
        Parameters:
        -----------
        N/A
        
        Returns:
        --------
        N/A
        """
        # Read in the grid's dimensions
        self._n_nodes = self.mediator.get_dimension_variable('node')
        self._n_elems = self.mediator.get_dimension_variable('element')
        self._n_siglev = self.mediator.get_dimension_variable('siglev')
        self._n_siglay = self.mediator.get_dimension_variable('siglay')
        
        # Grid connectivity/adjacency
        self._nv = self.mediator.get_grid_variable('nv', (3, self._n_elems), DTYPE_INT)
        self._nbe = self.mediator.get_grid_variable('nbe', (3, self._n_elems), DTYPE_INT)

        # Raw grid x/y or lat/lon coordinates
        coordinate_system = self.config.get("OCEAN_CIRCULATION_MODEL", "coordinate_system").strip().lower()
        if coordinate_system == "cartesian":
            x = self.mediator.get_grid_variable('x', (self._n_nodes), DTYPE_FLOAT)
            y = self.mediator.get_grid_variable('y', (self._n_nodes), DTYPE_FLOAT)
            xc = self.mediator.get_grid_variable('xc', (self._n_elems), DTYPE_FLOAT)
            yc = self.mediator.get_grid_variable('yc', (self._n_elems), DTYPE_FLOAT)

            # calculate offsets
            self._xmin = np.min(x)
            self._ymin = np.min(y)

        elif coordinate_system == "spherical":
            x = self.mediator.get_grid_variable('longitude', (self._n_nodes), DTYPE_FLOAT)
            y = self.mediator.get_grid_variable('latitude', (self._n_nodes), DTYPE_FLOAT)
            xc = self.mediator.get_grid_variable('longitude_c', (self._n_elems), DTYPE_FLOAT)
            yc = self.mediator.get_grid_variable('latitude_c', (self._n_elems), DTYPE_FLOAT)

            # Don't apply offsets in spherical case - set them to 0.0!
            self._xmin = 0.0
            self._ymin = 0.0
        else:
            raise ValueError("Unsupported model coordinate system `{}'".format(coordinate_system))

        # Apply offsets
        self._x = x - self._xmin
        self._y = y - self._ymin
        self._xc = xc - self._xmin
        self._yc = yc - self._ymin

        # Initialise unstructured grid
        self._unstructured_grid = UnstructuredGrid(self.config, self._name, self._n_nodes, self._n_elems, self._nv,
                                                   self._nbe, self._x, self._y, self._xc, self._yc)

        # Sigma levels at nodal coordinates
        self._siglev = self.mediator.get_grid_variable('siglev', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
        
        # Sigma layers at nodal coordinates
        self._siglay = self.mediator.get_grid_variable('siglay', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

        # Bathymetry
        self._h = self.mediator.get_grid_variable('h', (self._n_nodes), DTYPE_FLOAT)

    cdef _read_time_dependent_vars(self):
        """ Update time variables and memory views for FVCOM data fields.
        
        For each FVCOM time-dependent variable needed by PyLag two references
        are stored. These correspond to the last and next time points at which
        FVCOM data was saved. Together these bound PyLag's current time point.
        
        All communications go via the mediator in order to guarantee support for
        both serial and parallel simulations.
        
        Parameters:
        -----------
        N/A
        
        Returns:
        --------
        N/A
        """
        # Update time references
        self._time_last = self.mediator.get_time_at_last_time_index()
        self._time_next = self.mediator.get_time_at_next_time_index()
        
        # Update memory views for zeta
        self._zeta_last = self.mediator.get_time_dependent_variable_at_last_time_index('zeta', (self._n_nodes), DTYPE_FLOAT)
        self._zeta_next = self.mediator.get_time_dependent_variable_at_next_time_index('zeta', (self._n_nodes), DTYPE_FLOAT)
        
        # Update memory views for u, v and w
        self._u_last = self.mediator.get_time_dependent_variable_at_last_time_index('u', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._u_next = self.mediator.get_time_dependent_variable_at_next_time_index('u', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._v_last = self.mediator.get_time_dependent_variable_at_last_time_index('v', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._v_next = self.mediator.get_time_dependent_variable_at_next_time_index('v', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._w_last = self.mediator.get_time_dependent_variable_at_last_time_index('ww', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        self._w_next = self.mediator.get_time_dependent_variable_at_next_time_index('ww', (self._n_siglay, self._n_elems), DTYPE_FLOAT)
        
        # Update memory views for kh
        if self._has_Kh:
            self._kh_last = self.mediator.get_time_dependent_variable_at_last_time_index('kh', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)
            self._kh_next = self.mediator.get_time_dependent_variable_at_next_time_index('kh', (self._n_siglev, self._n_nodes), DTYPE_FLOAT)

        # Update memory views for viscofh
        if self._has_Ah:
            self._viscofh_last = self.mediator.get_time_dependent_variable_at_last_time_index('viscofh', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)
            self._viscofh_next = self.mediator.get_time_dependent_variable_at_next_time_index('viscofh', (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

        # Update memory views for wet cells
        if self._has_is_wet:
            self._wet_cells_last = self.mediator.get_time_dependent_variable_at_last_time_index('wet_cells', (self._n_elems), DTYPE_INT)
            self._wet_cells_next = self.mediator.get_time_dependent_variable_at_next_time_index('wet_cells', (self._n_elems), DTYPE_INT)

        # Read in data as requested
        if 'thetao' in self.env_var_names:
            fvcom_var_name = variable_library.fvcom_variable_names['thetao']
            self._thetao_last = self.mediator.get_time_dependent_variable_at_last_time_index(fvcom_var_name, (self._n_siglay, self._n_nodes), DTYPE_FLOAT)
            self._thetao_next = self.mediator.get_time_dependent_variable_at_next_time_index(fvcom_var_name, (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

        if 'so' in self.env_var_names:
            fvcom_var_name = variable_library.fvcom_variable_names['so']
            self._so_last = self.mediator.get_time_dependent_variable_at_last_time_index(fvcom_var_name, (self._n_siglay, self._n_nodes), DTYPE_FLOAT)
            self._so_next = self.mediator.get_time_dependent_variable_at_next_time_index(fvcom_var_name, (self._n_siglay, self._n_nodes), DTYPE_FLOAT)

        return

    cdef DTYPE_FLOAT_t _interp_on_sigma_layer(self,
            const vector[DTYPE_FLOAT_t] &phi, DTYPE_INT_t host,
            DTYPE_INT_t kidx)  except FLOAT_ERR:
        """ Return the linearly interpolated value of sigma on the sigma layer.
        
        Compute sigma on the specified sigma layer within the given host 
        element.
        
        Parameters
        ----------
        phi : vector, float
            Array of length three giving the barycentric coordinates at which 
            to interpolate

        host : int
            Host element index

        kidx : int
            Sigma layer on which to interpolate

        Returns
        -------
        sigma: float
            Interpolated value of sigma.
        """
        cdef int vertex # Vertex identifier
        cdef vector[DTYPE_FLOAT_t] sigma_nodes = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef DTYPE_FLOAT_t sigma # Sigma

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            sigma_nodes[i] = self._siglay[kidx, vertex]                  

        sigma = interp.interpolate_within_element(sigma_nodes, phi)
        return sigma

    cdef DTYPE_FLOAT_t _interp_on_sigma_level(self, 
            const vector[DTYPE_FLOAT_t] &phi, DTYPE_INT_t host,
            DTYPE_INT_t kidx) except FLOAT_ERR:
        """ Return the linearly interpolated value of sigma.
        
        Compute sigma on the specified sigma level within the given host 
        element.
        
        Parameters:
        -----------
        phi : vector, float
            Array of length three giving the barycentric coordinates at which 
            to interpolate.
            
        host : int
            Host element index.

        kidx : int
            Sigma layer on which to interpolate.

        Returns:
        --------
        sigma: float
            Interpolated value of sigma.
        """
        cdef int vertex # Vertex identifier
        cdef vector[DTYPE_FLOAT_t] sigma_nodes = vector[DTYPE_FLOAT_t](N_VERTICES, -999.)
        cdef DTYPE_FLOAT_t sigma # Sigma

        for i in xrange(N_VERTICES):
            vertex = self._nv[i,host]
            sigma_nodes[i] = self._siglev[kidx, vertex]                  

        sigma = interp.interpolate_within_element(sigma_nodes, phi)
        return sigma

