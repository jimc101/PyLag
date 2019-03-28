import numpy as np
import copy
import datetime
from netCDF4 import num2date

# Data types used for constructing C data structures
from pylag.data_types_python import DTYPE_INT, DTYPE_FLOAT
from data_types_cython cimport DTYPE_INT_t, DTYPE_FLOAT_t

from pylag.numerics import get_global_time_step

cdef class TimeManager(object):
    cdef object _config

    cdef object _datetime_start_str

    cdef DTYPE_INT_t _number_of_particle_releases

    cdef DTYPE_FLOAT_t _particle_release_interval_in_hours

    cdef DTYPE_INT_t _current_release

    cdef object _datetime_start
    cdef object _datetime_start_ref
    cdef object _datetime_end

    cdef DTYPE_FLOAT_t _time_start
    cdef DTYPE_FLOAT_t _time_end
    cdef DTYPE_FLOAT_t _time

    cdef DTYPE_FLOAT_t _time_step

    cdef DTYPE_FLOAT_t _output_frequency
    cdef DTYPE_FLOAT_t _sync_frequency
    cdef DTYPE_FLOAT_t _restart_frequency

    def __init__(self, config):
        # Config object
        self._config = config

        # Simulation start time - if running with multiple particle releases,
        # this is the time at which the first group of particles is released.
        self._datetime_start_str = config.get("SIMULATION", "start_datetime")

        # The number of particle releases
        self._number_of_particle_releases = config.getint("SIMULATION", "number_of_particle_releases")

        # Time interval between particle releases
        self._particle_release_interval_in_hours = config.getfloat("SIMULATION", "particle_release_interval_in_hours")

        # Period at which data is written to file
        self._output_frequency = config.getfloat("SIMULATION", "output_frequency")

        # Period at which data is synced to disk
        self._sync_frequency = config.getfloat("SIMULATION", "sync_frequency")

        # Period at which restart files are created
        self._restart_frequency = config.getfloat("RESTART", "restart_frequency")

        # Simulation time step
        self._time_step = get_global_time_step(config)

        # Check that the time step is an exact divisor of the output frequency
        if <int>self._output_frequency % <int>self._time_step != 0:
            raise RuntimeError("The simulation time step {} s should be an "
                    "exact divisor of the output frequency {}".format(self._time_step, self._output_frequency))

        # Check that the time step is an exact divisor of the sync frequency
        if <int>self._sync_frequency % <int>self._time_step != 0:
            raise RuntimeError("The simulation time step {} s should be an "
                    "exact divisor of the sync frequency {}".format(self._time_step, self._sync_frequency))

        # Initialise counter for the current particle release
        self._current_release = 0

    def _set_time_vars(self):
        """ Set time variables for the current particle release

        Initialise all time variables required to control a given particle
        release.
        """
        self._datetime_start_ref = datetime.datetime.strptime(self._datetime_start_str, "%Y-%m-%d %H:%M:%S")
        self._datetime_start = self._datetime_start_ref + datetime.timedelta(hours=self._particle_release_interval_in_hours) * self._current_release

        # If the simulation involves just a single particle release use
        # end_datetime to set the simulation end time.
        if self._number_of_particle_releases == 1:
            datetime_end_str = self._config.get("SIMULATION", "end_datetime")
            self._datetime_end = datetime.datetime.strptime(datetime_end_str, "%Y-%m-%d %H:%M:%S")
        else:
            duration_in_days = self._config.getfloat("SIMULATION", "duration_in_days")
            self._datetime_end = self._datetime_start + datetime.timedelta(days=duration_in_days)

        if self._datetime_end <= self._datetime_start:
            raise ValueError("Invalid end time. The specified end time ({}) is before the simulation start "
                             "time ({})".format(self._datetime_end, self._datetime_start))

        # Convert time counters to seconds
        self._time_start = 0.0
        self._time_end = (self._datetime_end - self._datetime_start).total_seconds()

        # Set the current time to time_start
        self._time = self._time_start

    def new_simulation(self):
        """Start a new simulation?

        If True, (re-)set all time variables and counters, then increment the
        indentifier for the current particle release.
        """
        if self._current_release >= self._number_of_particle_releases:
            return False

        self._set_time_vars()

        self._current_release += 1

        return True

    def update_current_time(self):
        self._time = self._time + self._time_step

    def write_output_to_file(self):
        cdef DTYPE_FLOAT_t time_diff

        time_diff = self._time - self._time_start
        if <int>time_diff % <int>self._output_frequency == 0:
            return 1
        return 0

    def sync_data_to_disk(self):
        cdef DTYPE_FLOAT_t time_diff

        time_diff = self._time - self._time_start
        if <int>time_diff % <int>self._sync_frequency == 0:
            return 1
        return 0

    def create_restart_file(self):
        cdef DTYPE_FLOAT_t time_diff

        time_diff = self._time - self._time_start
        if <int>time_diff % <int>self._restart_frequency == 0:
            return 1
        return 0

    # Properties
    # ----------

    # The total number of particle releases
    property number_of_particle_releases:
        def __get__(self):
            return self._number_of_particle_releases

    # Integer identifying the current particle release
    property current_release:
        def __get__(self):
            return self._current_release

    # Integration start datetime for the current release
    property datetime_start:
        def __get__(self):
            return self._datetime_start

    # Integration end datetime for the current release
    property datetime_end:
        def __get__(self):
            return self._datetime_end

    # Current datetime
    property datetime_current:
        def __get__(self):
            return num2date(self._time, units='seconds since {}'.format(self._datetime_start))

    # Current time (seconds elapsed since start of the current simulation)
    property time:
        def __get__(self):
            return self._time

    # Integration time step (seconds)
    property time_step:
        def __get__(self):
            return self._time_step

     # Integration end time (seconds)
    property time_end:
        def __get__(self):
            return self._time_end

