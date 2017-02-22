import logging

# Data types used for constructing C data structures
from pylag.data_types_python import DTYPE_INT, DTYPE_FLOAT
from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

from pylag.integrator import get_num_integrator
from pylag.random_walk import get_vertical_random_walk_model, get_horizontal_random_walk_model
from pylag.boundary_conditions import get_horiz_boundary_condition_calculator, get_vert_boundary_condition_calculator
from pylag.particle_positions_reader import read_particle_initial_positions
from pylag.particle import ParticleSmartPtr

from libcpp.vector cimport vector

from pylag.data_reader cimport DataReader
from pylag.math cimport sigma_to_cartesian_coords, cartesian_to_sigma_coords
from pylag.integrator cimport NumIntegrator
from pylag.random_walk cimport VerticalRandomWalk, HorizontalRandomWalk
from pylag.boundary_conditions cimport HorizBoundaryConditionCalculator, VertBoundaryConditionCalculator
from pylag.delta cimport Delta, reset
from pylag.particle cimport Particle, ParticleSmartPtr, copy

cdef class OPTModel:
    def set_particle_data(self, group_ids, x_positions, y_positions, z_positions):
        pass
    
    def setup_input_data_access(self, start_datetime, end_datetime):
        pass

    def read_input_data(self, time):
        pass

    def seed(self, time):
        pass
    
    cpdef update(self, DTYPE_FLOAT_t time):
        pass
    
    def get_diagnostics(self, time):
        pass
    
cdef class FVCOMOPTModel(OPTModel):
    """ FVCOM Offline Particle Tracking Model.
    
    Offline particle tracking moodel implementation that is tailored to work 
    with data generated by the FVCOM.
    
    Parameters:
    -----------
    config : SafeConfigParser
        Configuration obect.
    
    data_reader : FVCOMDataReader
        FVCOM data reader.
    """
    cdef object config
    cdef DataReader data_reader
    cdef NumIntegrator num_integrator
    cdef VerticalRandomWalk vert_rand_walk_model
    cdef HorizontalRandomWalk horiz_rand_walk_model
    cdef HorizBoundaryConditionCalculator horiz_bc_calculator
    cdef VertBoundaryConditionCalculator vert_bc_calculator
    cdef object particle_seed_smart_ptrs
    cdef object particle_smart_ptrs
    cdef vector[Particle*] particle_ptrs
    
    # Seed particle data (as read from file)
    cdef DTYPE_INT_t[:] _group_ids
    cdef DTYPE_FLOAT_t[:] _x_positions
    cdef DTYPE_FLOAT_t[:] _y_positions
    cdef DTYPE_FLOAT_t[:] _z_positions
    
    # Time step
    cdef DTYPE_FLOAT_t time_step 

    def __init__(self, config, data_reader, *args, **kwargs):
        # Initialise config
        self.config = config

        # Initialise model data reader
        self.data_reader = data_reader

        # Create boundary conditions calculators
        self.horiz_bc_calculator = get_horiz_boundary_condition_calculator(self.config)
        self.vert_bc_calculator = get_vert_boundary_condition_calculator(self.config)
        
        # Create numerical integrator
        self.num_integrator = get_num_integrator(self.config)

        # Create vertical random walk model
        self.vert_rand_walk_model = get_vertical_random_walk_model(self.config)

        # Create horizontal random walk model
        self.horiz_rand_walk_model = get_horizontal_random_walk_model(self.config)
        
        # Time step
        self.time_step = self.config.getfloat('SIMULATION', 'time_step')

    def set_particle_data(self, group_ids, x_positions, y_positions, z_positions):
        """Initialise memory views for data describing the particle seed.

        Parameters:
        -----------
        group_ids : ndarray, int
            Particle groups IDs.

        x_positions : ndarray, float
            Particle x-positions.

        y_positions : ndarray, float
            Particle y-positions.

        z_positions : ndarray, float
            Particle z-positions.
        """
        self._group_ids = group_ids
        self._x_positions = x_positions
        self._y_positions = y_positions
        self._z_positions = z_positions

    def setup_input_data_access(self, start_datetime, end_datetime):
        """Setup access to FVCOM time dependent variables.

        Parameters:
        -----------
        start_datime : Datetime
            The simulation start date and time.

        end_datime : Datetime
            The simulation end date and time.
        """
        self.data_reader.setup_data_access(start_datetime, end_datetime)

    def read_input_data(self, time):
        """Update reading frames for FVCOM data fields.

        Parameters:
        -----------
        time : float
            The current time.
        """
        self.data_reader.read_data(time)

    def seed(self, time=None):
        """Set particle positions equal to those of the particle seed.
        
        Create the particle seed if it has not been created already. Make
        an `active' copy of the particle seed.

        Parameters:
        -----------
        time : float
            The current time.
        """
        if self.particle_seed_smart_ptrs is None:
            self._create_seed(time)

        # Destroy the current active particle set and all pointers to it
        self.particle_smart_ptrs = []
        self.particle_ptrs.clear()

        for particle_seed_smart_ptr in self.particle_seed_smart_ptrs:
            particle_smart_ptr = copy(particle_seed_smart_ptr)
            self.particle_smart_ptrs.append(particle_smart_ptr)
            self.particle_ptrs.push_back(particle_smart_ptr.get_ptr())

    def _create_seed(self, time):
        """Create the particle seed.
        
        Create the particle seed using the supplied arguments. Initialise
        the active particle set using seed particles. A separate copy of the 
        particle seed is stored so that the model can be reseeded at a later 
        time, as may be required during ensemble simulations.

        Parameters:
        -----------
        time : float
            The current time.        
        """
        # Grid boundary limits
        cdef DTYPE_FLOAT_t zmin
        cdef DTYPE_FLOAT_t zmax
        
        # Particle raw pointer
        cdef Particle* particle_ptr
        
        # Create particle seed - particles stored in a list object
        self.particle_seed_smart_ptrs = []

        guess = None
        particles_in_domain = 0
        for group, x, y, z_temp in zip(self._group_ids, self._x_positions, self._y_positions, self._z_positions):
            # Find particle host element
            if guess is not None:
                # Try a local search first
                flag, host_horizontal_elem = self.data_reader.find_host_using_local_search(x, y, guess)
                if flag < 0:
                    # Local search failed - try a global search
                    host_horizontal_elem = self.data_reader.find_host_using_global_search(x, y)
            else:
                # Global search ...
                host_horizontal_elem = self.data_reader.find_host_using_global_search(x, y)

            if host_horizontal_elem >= 0:
                in_domain = True

                # Create particle
                particle_seed_smart_ptr = ParticleSmartPtr(group_id=group,
                        xpos=x, ypos=y, host=host_horizontal_elem,
                        in_domain=in_domain)
                particle_ptr = particle_seed_smart_ptr.get_ptr()

                # Set local coordinates
                self.data_reader.set_local_coordinates(particle_ptr)

                # Set z depending on the specified coordinate system
                zmin = self.data_reader.get_zmin(time, particle_ptr)
                zmax = self.data_reader.get_zmax(time, particle_ptr)
                if self.config.get("SIMULATION", "depth_coordinates") == "cartesian":
                    # z is given as the distance below the free surface. We use
                    # this and zeta to determine the distance below the mean
                    # free surface, which is then used with h to calculate sigma
                    particle_ptr.zpos = z_temp + zmax
                    
                elif self.config.get("SIMULATION", "depth_coordinates") == "sigma":
                    # Convert to cartesian coords using zmin and zmax
                    particle_ptr.zpos = sigma_to_cartesian_coords(z_temp, zmin, zmax)
                
                # Check that the given depth is valid
                if particle_ptr.zpos < zmin:
                    raise ValueError("Supplied depth z (= {}) lies below the sea floor (h = {}).".format(particle_ptr.zpos,zmin))
                elif particle_ptr.zpos > zmax:
                    raise ValueError("Supplied depth z (= {}) lies above the free surface (zeta = {}).".format(particle_ptr.zpos,zmax))

                # Find the host z layer
                particle_ptr.host_z_layer = self.data_reader.set_vertical_grid_vars(time, particle_ptr)

                # Add particle to the particle set
                self.particle_seed_smart_ptrs.append(particle_seed_smart_ptr)

                particles_in_domain += 1

                # Use the location of the last particle to guide the search for the
                # next. This should be fast if particle initial positions are colocated.
                guess = host_horizontal_elem
            else:
                in_domain = False
                particle_seed_smart_ptr = ParticleSmartPtr(group_id=group, in_domain=in_domain)
                self.particle_seed_smart_ptrs.append(particle_seed_smart_ptr)

        if self.config.get('GENERAL', 'log_level') == 'DEBUG':
            logger = logging.getLogger(__name__)
            logger.info('{} of {} particles are located in the model domain.'.format(particles_in_domain, len(self.particle_seed_smart_ptrs)))

    cpdef update(self, DTYPE_FLOAT_t time):
        """ Compute and update each particle's position.
        
        Compute the net effect of resolved and unresolved processes on particle
        motion in the interval t -> t + dt. Resolved velocities are used to
        advect particles. A random displacement model is used to model the
        effect of unresolved (subgrid scale) vertical and horizontal transport
        processes. Particle displacements are first stored and accumulated in an
        object of type Delta before then being used to update a given particle's
        position.
        
        If a particle crosses a land boundary its motion is temporarily
        arrested. If the particle crosses an open boundary it is flagged as
        having left the domain. These checks are performed twice - the first
        after the advection call and the second after the net effect of each
        process has been summed. The former is implemented in order to catch
        errors thrown by the numerical integration scheme - these often employ
        multi-step process which will error if the particle exits the domain 
        mid-way through the computation.
        
        In the vertical, reflecting boundary conditions are applied at the 
        bottom and surface boundaries.
        
        Parameters:
        -----------
        time : float
            The current time.
        """
        cdef DTYPE_FLOAT_t xpos, ypos, zpos
        cdef DTYPE_FLOAT_t zmin, zmax
        cdef Delta delta_X
        cdef Particle* particle_ptr
        cdef DTYPE_INT_t flag, host, host_err
        cdef DTYPE_INT_t i, n_particles
        
        # Cycle over the particle set, updating the position of only those
        # particles that remain in the model domain
        for particle_ptr in self.particle_ptrs:
            if particle_ptr.in_domain:
                reset(&delta_X)
                
                # Advection
                if self.num_integrator is not None:
                    host_err = self.num_integrator.advect(time,
                            particle_ptr, self.data_reader, &delta_X)
                            
                    if host_err == -2:
                        particle_ptr.in_domain = False
                        continue
                
                # Vertical random walk
                if self.vert_rand_walk_model is not None:
                    self.vert_rand_walk_model.random_walk(time, particle_ptr, 
                            self.data_reader, &delta_X)

                # Horizontal random walk
                if self.horiz_rand_walk_model is not None:
                    self.horiz_rand_walk_model.random_walk(time, particle_ptr, 
                            self.data_reader, &delta_X)  
                
                # Sum contributions
                xpos = particle_ptr.xpos + delta_X.x
                ypos = particle_ptr.ypos + delta_X.y
                zpos = particle_ptr.zpos + delta_X.z
                flag, host = self.data_reader.find_host(particle_ptr.xpos,
                        particle_ptr.ypos, xpos, ypos, particle_ptr.host_horizontal_elem)
              
                # First check for land boundary crossing
                while flag == -1:
                    xpos, ypos = self.horiz_bc_calculator.apply(self.data_reader,
                            particle_ptr.xpos, particle_ptr.ypos, xpos, ypos,
                            host)
                    flag, host = self.data_reader.find_host(particle_ptr.xpos,
                        particle_ptr.ypos, xpos, ypos, particle_ptr.host_horizontal_elem)

                # Second check for open boundary crossing
                if flag == -2:
                    particle_ptr.in_domain = False
                    continue

                # If the particle still resides in the domain update its position.
                if flag == 0:
                    # Update the particle's position
                    particle_ptr.xpos = xpos
                    particle_ptr.ypos = ypos
                    particle_ptr.zpos = zpos
                    particle_ptr.host_horizontal_elem = host

                    # Update particle local coordinates
                    self.data_reader.set_local_coordinates(particle_ptr)

                    # Apply surface/bottom boundary conditions and set zpos
                    # NB zmin and zmax evaluated at the new time t+dt
                    zmin = self.data_reader.get_zmin(time+self.time_step, particle_ptr)
                    zmax = self.data_reader.get_zmax(time+self.time_step, particle_ptr)
                    if particle_ptr.zpos < zmin or particle_ptr.zpos > zmax:
                        particle_ptr.zpos = self.vert_bc_calculator.apply(particle_ptr.zpos, zmin, zmax)

                    # Determine the new host zlayer
                    particle_ptr.host_z_layer = self.data_reader.set_vertical_grid_vars(time+self.time_step, particle_ptr)
                else:
                    raise ValueError('Unrecognised host element flag {}.'.format(host))

    def get_diagnostics(self, time):
        """ Get particle diagnostics
        
        Parameters:
        -----------
        time : float
            The current time.
        
        Returns:
        --------
        diags : dict
            Dictionary holding particle diagnostic data.
        """
        cdef Particle* particle_ptr
        
        diags = {'xpos': [], 'ypos': [], 'zpos': [], 'host_horizontal_elem': [], 'h': [], 'zeta': []}
        for particle_ptr in self.particle_ptrs:
            diags['xpos'].append(particle_ptr.xpos)
            diags['ypos'].append(particle_ptr.ypos)
            diags['zpos'].append(particle_ptr.zpos)
            diags['host_horizontal_elem'].append(particle_ptr.host_horizontal_elem)            
            
            # Derived vars including depth, which is first converted to cartesian coords
            h = self.data_reader.get_zmin(time, particle_ptr)
            zeta = self.data_reader.get_zmax(time, particle_ptr)
            diags['h'].append(h)
            diags['zeta'].append(zeta)
        return diags

cdef class GOTMOPTModel(OPTModel):
    """ GOTM Offline Particle Tracking Model.
    
    Offline particle tracking model implementation that is tailored to work 
    with data generated by the GOTM.
    
    Parameters:
    -----------
    config : SafeConfigParser
        Configuration obect.
    
    data_reader : GOTMDataReader
        GOTM data reader.
    """
    cdef object config
    cdef DataReader data_reader
    cdef VerticalRandomWalk vert_rand_walk_model
    cdef VertBoundaryConditionCalculator vert_bc_calculator
    cdef object particle_seed_smart_ptrs
    cdef object particle_smart_ptrs
    cdef vector[Particle*] particle_ptrs
    
    # Seed particle data (as read from file)
    cdef DTYPE_INT_t[:] _group_ids
    cdef DTYPE_FLOAT_t[:] _x_positions
    cdef DTYPE_FLOAT_t[:] _y_positions
    cdef DTYPE_FLOAT_t[:] _z_positions
    
    # Time step
    cdef DTYPE_FLOAT_t time_step 

    def __init__(self, config, data_reader, *args, **kwargs):
        # Initialise config
        self.config = config

        # Initialise model data reader
        self.data_reader = data_reader

        # Create vertical random walk model
        self.vert_rand_walk_model = get_vertical_random_walk_model(self.config)

        # Create vertical boundary conditions calculator
        self.vert_bc_calculator = get_vert_boundary_condition_calculator(self.config)

        # Time step
        self.time_step = self.config.getfloat('SIMULATION', 'time_step')

    def set_particle_data(self, group_ids, x_positions, y_positions, z_positions):
        """Initialise memory views for data describing the particle seed.

        Parameters:
        -----------
        group_ids : ndarray, int
            Particle groups IDs.

        x_positions : ndarray, float
            Particle x-positions.

        y_positions : ndarray, float
            Particle y-positions.

        z_positions : ndarray, float
            Particle z-positions.
        """
        self._group_ids = group_ids
        self._x_positions = x_positions
        self._y_positions = y_positions
        self._z_positions = z_positions

    def setup_input_data_access(self, start_datetime, end_datetime):
        """Setup access to FVCOM time dependent variables.

        Parameters:
        -----------
        start_datime : Datetime
            The simulation start date and time.

        end_datime : Datetime
            The simulation end date and time.
        """
        self.data_reader.setup_data_access(start_datetime, end_datetime)

    def read_input_data(self, time):
        """Update reading frames for FVCOM data fields.

        Parameters:
        -----------
        time : float
            The current time.
        """
        self.data_reader.read_data(time)

    def seed(self, time=None):
        """Set particle positions equal to those of the particle seed.
        
        Create the particle seed if it has not been created already. Make
        an `active' copy of the particle seed.

        Parameters:
        -----------
        time : float
            The current time.
        """
        if self.particle_seed_smart_ptrs is None:
            self._create_seed(time)

        # Destroy the current active particle set and all pointers to it
        self.particle_smart_ptrs = []
        self.particle_ptrs.clear()

        for particle_seed_smart_ptr in self.particle_seed_smart_ptrs:
            particle_smart_ptr = copy(particle_seed_smart_ptr)
            self.particle_smart_ptrs.append(particle_smart_ptr)
            self.particle_ptrs.push_back(particle_smart_ptr.get_ptr())

    def _create_seed(self, time):
        """Create the particle seed.
        
        Create the particle seed using the supplied arguments. Initialise
        the active particle set using seed particles. A separate copy of the 
        particle seed is stored so that the model can be reseeded at a later 
        time, as may be required during ensemble simulations.

        Parameters:
        -----------
        time : float
            The current time.
        """
        # Particle raw pointer
        cdef Particle* particle_ptr

        # Create particle seed - particles stored in a list object
        self.particle_seed_smart_ptrs = []
        for group, x, y, z_temp in zip(self._group_ids, self._x_positions,
                self._y_positions, self._z_positions):
            # Particle in the domain - this is a 1D column model.
            in_domain = True
            
            # Host set to 0
            host = 0
    
            # Create particle
            particle_seed_smart_ptr = ParticleSmartPtr(group_id=group,
                    xpos=x, ypos=y, host=host, in_domain=in_domain)
            particle_ptr = particle_seed_smart_ptr.get_ptr()

            # Set z depending on the specified coordinate system
            zmin = self.data_reader.get_zmin(time, particle_ptr)
            zmax = self.data_reader.get_zmax(time, particle_ptr)
            if self.config.get("SIMULATION", "depth_coordinates") == "cartesian":
                # z is given as the distance below the free surface. We use
                # this and zeta to determine the distance below the mean
                # free surface, which is then used with h to calculate sigma
                particle_ptr.zpos = z_temp + zmax

            elif self.config.get("SIMULATION", "depth_coordinates") == "sigma":
                # Convert to cartesian coords using zmin and zmax
                particle_ptr.zpos = sigma_to_cartesian_coords(z_temp, zmin, zmax)

            # Check that the given depth is valid
            if particle_ptr.zpos < zmin:
                raise ValueError("Supplied depth z (= {}) lies below the sea floor (h = {}).".format(particle_ptr.zpos,zmin))
            elif particle_ptr.zpos > zmax:
                raise ValueError("Supplied depth z (= {}) lies above the free surface (zeta = {}).".format(particle_ptr.zpos,zmax))

            # Find the host z layer
            particle_ptr.host_z_layer = self.data_reader.set_vertical_grid_vars(time, particle_ptr)

            # Add particle to the set
            self.particle_seed_smart_ptrs.append(particle_seed_smart_ptr)

    cpdef update(self, DTYPE_FLOAT_t time):
        """ Compute and update each particle's position.
        
        Reflecting boundary conditions are applied at the bottom and surface
        boundaries.
        
        Parameters:
        -----------
        time : float
            The current time.
        """
        cdef DTYPE_FLOAT_t zpos

        cdef DTYPE_FLOAT_t zmin, zmax

        cdef Delta delta_X

        cdef Particle* particle_ptr

        cdef DTYPE_INT_t i, n_particles

        # Cycle over the particle set, updating the position of only those
        # particles that remain in the model domain
        for particle_ptr in self.particle_ptrs:
            if particle_ptr.in_domain:
                reset(&delta_X)

                # Find the host z layer for the current time
                particle_ptr.host_z_layer = self.data_reader.set_vertical_grid_vars(time,
                    particle_ptr)

                # Vertical random walk
                if self.vert_rand_walk_model is not None:
                    self.vert_rand_walk_model.random_walk(time, particle_ptr, 
                            self.data_reader, &delta_X)

                # Sum contributions
                zpos = particle_ptr.zpos + delta_X.z

                # Apply surface/bottom boundary conditions
                # NB zmin and zmax evaluated at the new time t+dt
                zmin = self.data_reader.get_zmin(time+self.time_step, particle_ptr)
                zmax = self.data_reader.get_zmax(time+self.time_step, particle_ptr)
                if zpos < zmin or zpos > zmax:
                    zpos = self.vert_bc_calculator.apply(zpos, zmin, zmax)

                # Update the particle's position
                particle_ptr.zpos = zpos

    def get_diagnostics(self, time):
        """ Get particle diagnostics
        
        Parameters:
        -----------
        time : float
            The current time.
        
        Returns:
        --------
        diags : dict
            Dictionary holding particle diagnostic data.
        """
        cdef Particle* particle_ptr
        
        diags = {'xpos': [], 'ypos': [], 'zpos': [], 'host_horizontal_elem': [], 'h': [], 'zeta': []}
        for particle_ptr in self.particle_ptrs:
            diags['xpos'].append(particle_ptr.xpos)
            diags['ypos'].append(particle_ptr.ypos)
            diags['zpos'].append(particle_ptr.zpos)
            diags['host_horizontal_elem'].append(particle_ptr.host_horizontal_elem)            
            
            # Derived vars including depth, which is first converted to cartesian coords
            h = self.data_reader.get_zmin(time, particle_ptr)
            zeta = self.data_reader.get_zmax(time, particle_ptr)
            diags['h'].append(h)
            diags['zeta'].append(zeta)
        return diags
