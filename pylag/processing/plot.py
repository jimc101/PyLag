"""
PyLag plotting functions
"""

from __future__ import division, print_function

import numpy as np
from scipy import interp
import collections
import matplotlib as mpl
from matplotlib import pyplot as plt
from matplotlib.tri.triangulation import Triangulation
from mpl_toolkits.axes_grid1 import make_axes_locatable
import cartopy.crs as ccrs
from cartopy.mpl.gridliner import LONGITUDE_FORMATTER, LATITUDE_FORMATTER
from netCDF4 import Dataset
from cftime import num2pydate
from cmocean import cm

from PyFVCOM.plot import cm2inch

from pylag.processing.ncview import Viewer
from pylag.processing.utils import round_time
from pylag.processing.ensemble import get_probability_density_1D


class PyLagPlotter:
    """ Create PyLag plot objects
    
    Class to assist in the creation of plots and animations. This is the
    default PyLag plotter, designed to work with PyLag simulation output
    that has been generated using input data that is defined on a single
    horizontal mesh. The mesh is read from the run's grid metrics file,
    which must be passed to PyLagPlotter during class initialisation.

    Specifically, PyLagPlotter will work with:

    1) Arakawa A-grid derived data
    2) FVCOM derived data

    Parameters
    ----------
    grid_metrics_file : Dataset or str
        This is either the path to a PyLag grid metrics file or a
        NetCDF Dataset object. If the former, PyLagPlotter will try to
        instantiate a new Dataset using the supplied file name.

    geospatial_coords : boolean, optional
        Boolean specifying whether or not to use cartopy to create a 2D map
        on top of which the data will be plotted. The default option is
        `True`. If `False`, a simple Cartesian grid is drawn instead.

    font_size : int, optional
        Font size to use when rendering plot text

    line_width : float, optional
        Default line width to use when plotting

    """
    def __init__(self, grid_metrics_file, geospatial_coords=True, font_size=10, line_width=0.2):
        if isinstance(grid_metrics_file, Dataset):
            ds = grid_metrics_file
        elif isinstance(grid_metrics_file, str):
            ds = Dataset(grid_metrics_file, 'r')
        else:
            raise ValueError("`grid_metrics_file` should be either a pre-constructed netCDF.Dataset or a srting "\
                             "giving the path to a PyLag grid metrics file.")

        self.geospatial_coords = geospatial_coords

        self.font_size = font_size

        self.line_width = line_width

        # Initialise the figure
        self.__init_figure(ds)

        # Close the NetCDF file for reading
        ds.close()
        del ds

    def __init_figure(self, ds):
        # Read in the required grid variables
        self.n_nodes = len(ds.dimensions['node'])
        self.n_elems = len(ds.dimensions['element'])
        self.nv = ds.variables['nv'][:]

        # Try to read the element mask
        try:
            self.maskc = ds.variables['mask'][:]
        except KeyError:
            self.maskc = None

        if self.geospatial_coords:
            self.x = ds.variables['longitude'][:]
            self.y = ds.variables['latitude'][:]
            self.xc = ds.variables['longitude_c'][:]
            self.yc = ds.variables['latitude_c'][:]
        else:
            self.x = ds.variables['x'][:]
            self.y = ds.variables['y'][:]
            self.xc = ds.variables['xc'][:]
            self.yc = ds.variables['yc'][:]

        # Triangles
        self.triangles = self.nv.transpose()

        # Store triangulation
        self.tri = Triangulation(self.x, self.y, self.triangles, mask=self.maskc)

    def _get_default_extents(self):
        return np.array([self.x.min(),
                         self.x.max(),
                         self.y.min(),
                         self.y.max()])

    def plot_field(self, ax, field, update=False, configure=True, add_colour_bar=True, cb_label=None, tick_inc=True,
                   extents=None, transform=ccrs.PlateCarree(), draw_coastlines=False, resolution='10m',
                   **kwargs):
        """ Map the supplied field

        The field must be defined on the same triangular mesh that is defined in the grid metrics
        file (either nodes or element centres). Included here to make it possible to overlay
        particle tracks on different fields (e.g. bathymetry, temperature). If `geospatial_coords` is
        True, Cartopy will be used to graph the supplied field.

        Additional plotting options are passed to `matplotlib.pyplot.pcolormesh`. See the matplotlib documentation
        for a full list of supported options.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        field : 1D NumPy array
            The field to plot.

        update : bool, optional
            If true, update the existing plot. Specifically, the axes will be checked to see if it contains a
            PolyCollection object, as generated by tripcolor. If found, the associated data array will be
            updated with the supplied field data. This is faster than drawing a new map

        configure : bool, optional
            If true, configure the plot by setting plot extents, drawing coastlines etc. This can be
            useful when overlaying plots, and you only want to incur the cost of configuring the plot
            once. The default is True, with the expectation that in most circumstances users will
            draw any underlying field data before overlaying particle tracks. Default: True.

        add_colour_bar : bool, optional
            If true, draw a colour bar.

        cb_label : str, optional
            The colour bar label.

        tick_inc : bool, optional
            Add coordinate axes (i.e. lat/long).

        extents : 1D array, optional
            Four element numpy array giving lon/lat limits (e.g. [-4.56, -3.76,
            49.96, 50.44])

        transform : cartopy.crs.Projection
            Type of projection.

        draw_coastlines : boolean, optional
            Draw coastlines. Default False.

        resolution : str, optional
            Resolution to use when plotting the coastline. Only used when draw_coastline=True. Default: '10m'.

        Returns
        -------
        axes : matplotlib.axes.Axes
            Axes object

        plot : matplotlib.collections.PolyCollection
            The plot object
        """
        if update is True:
            for collection in ax.collections:
                if type(collection) == mpl.collections.PolyCollection:
                    collection.set_array(field)
                    return ax
            raise RuntimeError('Received update is True, but the current axis does not contain a PolyCollection object.')

        # If not configuring the plot, simply plot the field and return
        if not configure:
            if self.geospatial_coords:
                plot = ax.tripcolor(self.tri, field, transform=transform, **kwargs)
            else:
                plot = ax.tripcolor(self.tri, field, **kwargs)

            return ax

        # Set extents
        if extents is None:
            extents = self._get_default_extents()

        # Create plot
        if self.geospatial_coords:
            plot = ax.tripcolor(self.tri, field, transform=transform, **kwargs)
            ax.set_extent(extents, transform)

            if draw_coastlines:
                ax.coastlines(resolution=resolution, linewidth=self.line_width)

            if tick_inc:
                self._add_ticks(ax)

            ax.set_xlabel('Longitude (E)', fontsize=self.font_size)
            ax.set_ylabel('Longitude (N)', fontsize=self.font_size)
        else:
            plot = ax.tripcolor(self.tri, field, **kwargs)
            ax.set_extent(extents)

            ax.set_xlabel('x (m)', fontsize=self.font_size)
            ax.set_ylabel('y (m)', fontsize=self.font_size)

        # Add colour bar
        if add_colour_bar:
            figure = ax.get_figure()
            self._add_colour_bar(figure, ax, plot, cb_label)

        return ax, plot

    def _add_colour_bar(self, figure, axes, plot, cb_label=None):
        # Add colobar scaled to axis width
        divider = make_axes_locatable(axes)
        cax = divider.append_axes("right", size="5%", pad=0.05, axes_class=plt.Axes)
        cbar = figure.colorbar(plot, cax=cax)
        cbar.ax.tick_params(labelsize=self.font_size)
        if cb_label:
            cbar.set_label(cb_label, size=self.font_size)
        return

    def plot_lines(self, ax, x, y, **kwargs):
        """Plot path lines.

        In addition to the listed parameters, the function accepts all keyword arguments taken by the Matplotlib
        plot command.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        x : ND array
            Array of x coordinates to plot.

        y : ND array
            Array of y coordinates to plot.

        Returns
        -------
        axes : matplotlib.axes.Axes
            Axes object

        line_plot : matplotlib.collections.Line2D
            The plot object
        """
        # Use some better default attributes if they have not been supplied
        alpha = kwargs.pop('alpha', 0.25)
        color = kwargs.pop('color', 'r')
        linewidth = kwargs.pop('linewidth', 1.0)

        line_plots = ax.plot(x, y, zorder=3, alpha=alpha, color=color, linewidth=linewidth, **kwargs)

        return ax, line_plots

    def remove_line_plots(self, line_plots):
        """ Remove line plots

        Useful when updating plots for animations.

        Parameters
        ----------
        line_plots : list
            List of line plot objects created during call to plot_lines()
        """
        while line_plots:
            line_plots.pop(0).remove()

        return

    def scatter(self, ax, x, y, configure=False, transform=ccrs.PlateCarree(), zorder=4,
                extents=None, draw_coastlines=False, resolution='10m', tick_inc=False, **kwargs):
        """ Create a scatter plot using the provided x and y values

        If geospatial_coords is True, x and y should be geospatial (lat, lon) coordinates. If not, x any y should
        be given as cartesian coordinates.

        See Matplotlib's scatter documentation for a list of additional key
        word arguments.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        x : 1D array
            Array of 'x' positions. If plotting in geospatial coords, these should be longitudes.

        y : 1D array
            Array of 'y' positions. If plotting in geospatial coords, these should be latitudes.

        configure : bool, optional
            If true, configure the plot by setting plot extents, drawing coastlines etc. Default: False.

        transform : cartopy.crs.Projection
            The type of transform to perform if geospatial_coords is True. Optional.

        draw_coastlines : bool
            Draw coastlines? Only used if geospatial_coords is True. Optional.

        resolution : str, optional
            Resolution to use when plotting the coastline. Only used when draw_coastline=True. Default: '10m'.

        tick_inc : bool
            Draw ticks? Only used if geospatial_coords is True. Optional.

        Returns
        -------
        ax : matplotlib.axes.Axes
            Axes object

        scatter_plot : matplotlib.collection.PathCollection
            The scatter plot
        """
        # Check to see if a field has already been plotted, indicating we can simply overlay
        # particle positions without setting up the plot in full.
        if not configure:
            if self.geospatial_coords:
                scatter_plot = ax.scatter(x, y, transform=transform, zorder=zorder, **kwargs)
            else:
                scatter_plot = ax.scatter(x, y, zorder=zorder, **kwargs)

            return ax, scatter_plot

        # Create a new plot

        # Set extents
        if extents is None:
            extents = self._get_default_extents()

        # Create plot
        if self.geospatial_coords:
            scatter_plot = ax.scatter(x, y, transform=transform, zorder=zorder, **kwargs)
            ax.set_extent(extents, transform)

            if draw_coastlines:
                ax.coastlines(resolution=resolution, linewidth=self.line_width)

            if tick_inc:
                self._add_ticks(ax)
        else:
            scatter_plot = ax.scatter(x, y, zorder=zorder, **kwargs)
            ax.set_extent(extents)

            ax.set_xlabel('x (m)', fontsize=self.font_size)
            ax.set_ylabel('y (m)', fontsize=self.font_size)

        return ax, scatter_plot

    def draw_grid(self, ax, draw_masked_elements=False, **kwargs):
        """ Draw the underlying grid or mesh

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        draw_masked_elements : bool
            Include masked elements. Default False.

        Returns
        -------
        ax : matplotlib.axes.Axes
            Axes object
        """
        reinstate_mask = False
        if self.maskc is not None and draw_masked_elements:
            reinstate_mask = True
            self.tri.set_mask(None)

        ax.triplot(self.tri, zorder=2, **kwargs)

        # Reinstate the mask if needed
        if reinstate_mask:
            self.tri.set_mask(self.maskc)

    def set_title(self, ax, title):
        """ Set the title

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        title : str
            Plot title
        """
        ax.set_title(title, fontsize=self.font_size)

#    def get_nodal_coords(self):
#        return np.copy(self.x), np.copy(self.y)

    def _add_ticks(self, ax):
        gl = ax.gridlines(linewidth=self.line_width, draw_labels=True, linestyle='--', color='k')

        gl.xlabel_style = {'fontsize': self.font_size}
        gl.ylabel_style = {'fontsize': self.font_size}

        gl.xlabels_top=False
        gl.ylabels_right=False
        gl.xlabels_bottom=True
        gl.ylabels_left=True

        gl.xformatter = LONGITUDE_FORMATTER
        gl.yformatter = LATITUDE_FORMATTER


class ArakawaCPlotter:
    """ Create PyLag plot objects based on Arakawa C-grid inputs

    Class to assist in the creation of plots and animations for PyLag
    simulations that used input data defined on an Arakawa C-grid.
    The C-grid mesh is read from the run's grid metrics file, which must
    be passed to ArakawaCPlotter during class initialisation.

    Specifically, ArakawaCPlotter will work with:

    1) Arakawa C-grid derived data

    Parameters
    ----------
    grid_metrics_file : Dataset or str
        This is the path to the PyLag grid metrics file or a NetCDF4 dataset
        object that has been created from the grid metrics file.

    geospatial_coords : boolean, optional
        Boolean specifying whether or not to use cartopy to create a 2D map
        on top of which the data will be plotted. The default option is
        `True`. If `False`, a simple Cartesian grid is drawn instead.

    font_size : int, optional
        Font size to use when rendering plot text

    line_width : float, optional
        Default line width to use when plotting

    """

    def __init__(self, grid_metrics_file, geospatial_coords=True, font_size=10, line_width=0.2):
        if isinstance(grid_metrics_file, Dataset):
            ds = grid_metrics_file
        elif isinstance(grid_metrics_file, str):
            ds = Dataset(grid_metrics_file, 'r')
        else:
            raise ValueError("`grid_metrics_file` should be either a pre-constructed netCDF.Dataset or a srting " \
                             "giving the path to a PyLag grid metrics file.")

        self.geospatial_coords = geospatial_coords

        self.font_size = font_size

        self.line_width = line_width

        # Initialise the figure
        self.__init_figure(ds)

        # Close the NetCDF file for reading
        ds.close()
        del ds

    def __init_figure(self, ds):
        # Initialise dictionaries
        self.n_nodes = {}
        self.n_elems = {}
        self.nv = {}
        self.maskc = {}
        self.x = {}
        self.y = {}
        self.xc = {}
        self.yc = {}
        self.triangles = {}
        self.tri = {}

        # Read in the required grid variables per grid
        for grid_name in ['grid_u', 'grid_v', 'grid_rho']:

            # Check to see whether the file contains dimension variables for the given grid
            has_grid_info = False
            for dim_name in ds.dimensions.keys():
                if grid_name in dim_name:
                    has_grid_info = True
                    break

            # Pass on this grid if it is not present
            if has_grid_info is False:
                continue

            self.n_nodes[grid_name] = len(ds.dimensions['node_{}'.format(grid_name)])
            self.n_elems[grid_name] = len(ds.dimensions['element_{}'.format(grid_name)])
            self.nv[grid_name] = ds.variables['nv_{}'.format(grid_name)][:]

            # Try to read the element mask
            try:
                self.maskc[grid_name] = ds.variables['mask_{}'.format(grid_name)][:]
            except KeyError:
                self.maskc[grid_name] = None

            if self.geospatial_coords:
                self.x[grid_name] = ds.variables['longitude_{}'.format(grid_name)][:]
                self.y[grid_name] = ds.variables['latitude_{}'.format(grid_name)][:]
                self.xc[grid_name] = ds.variables['longitude_c_{}'.format(grid_name)][:]
                self.yc[grid_name] = ds.variables['latitude_c_{}'.format(grid_name)][:]
            else:
                self.x[grid_name] = ds.variables['x_{}'.format(grid_name)][:]
                self.y[grid_name] = ds.variables['y_{}'.format(grid_name)][:]
                self.xc[grid_name] = ds.variables['xc_{}'.format(grid_name)][:]
                self.yc[grid_name] = ds.variables['yc_{}'.format(grid_name)][:]

            # Triangles
            self.triangles[grid_name] = self.nv[grid_name].transpose()

            # Store triangulation
            self.tri[grid_name] = Triangulation(self.x[grid_name], self.y[grid_name], self.triangles[grid_name], mask=self.maskc[grid_name])

    def _get_default_extents(self, grid_name):
        return np.array([self.x[grid_name].min(),
                         self.x[grid_name].max(),
                         self.y[grid_name].min(),
                         self.y[grid_name].max()])

    def plot_field(self, ax, grid_name, field, update=False, configure=True, add_colour_bar=True, cb_label=None, tick_inc=True,
                   extents=None, transform=ccrs.PlateCarree(), draw_coastlines=False, resolution='10m',
                   **kwargs):
        """ Map the supplied field

        The field must be defined on the same triangular mesh that is defined in the grid metrics
        file (either nodes or element centres). Included here to make it possible to overlay
        particle tracks on different fields (e.g. bathymetry, temperature). If `geospatial_coords` is
        True, Cartopy will be used to graph the supplied field.

        Additional plotting options are passed to `matplotlib.pyplot.pcolormesh`. See the matplotlib documentation
        for a full list of supported options.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        grid_name : str
            The name of the grid on which the field data is defined

        field : 1D NumPy array
            The field to plot.

        update : bool, optional
            If true, update the existing plot. Specifically, the axes will be checked to see if it contains a
            PolyCollection object, as generated by tripcolor. If found, the associated data array will be
            updated with the supplied field data. This is faster than drawing a new map

        configure : bool, optional
            If true, configure the plot by setting plot extents, drawing coastlines etc. This can be
            useful when overlaying plots, and you only want to incur the cost of configuring the plot
            once. The default is True, with the expectation that in most circumstances users will
            draw any underlying field data before overlaying particle tracks. Default: True.

        add_colour_bar : bool, optional
            If true, draw a colour bar.

        cb_label : str, optional
            The colour bar label.

        tick_inc : bool, optional
            Add coordinate axes (i.e. lat/long).

        extents : 1D array, optional
            Four element numpy array giving lon/lat limits (e.g. [-4.56, -3.76,
            49.96, 50.44])

        transform : cartopy.crs.Projection
            Type of projection.

        draw_coastlines : boolean, optional
            Draw coastlines. Default False.

        resolution : str, optional
            Resolution to use when plotting the coastline. Only used when draw_coastline=True. Default: '10m'.

        Returns
        -------
        axes : matplotlib.axes.Axes
            Axes object

        plot : matplotlib.collections.PolyCollection
            The plot object
        """
        if update is True:
            for collection in ax.collections:
                if type(collection) == mpl.collections.PolyCollection:
                    collection.set_array(field)
                    return ax
            raise RuntimeError(
                'Received update is True, but the current axis does not contain a PolyCollection object.')

        # If not configuring the plot, simply plot the field and return
        if not configure:
            if self.geospatial_coords:
                plot = ax.tripcolor(self.tri[grid_name], field, transform=transform, **kwargs)
            else:
                plot = ax.tripcolor(self.tri[grid_name], field, **kwargs)

            return ax

        # Set extents
        if extents is None:
            extents = self._get_default_extents(grid_name)

        # Create plot
        if self.geospatial_coords:
            plot = ax.tripcolor(self.tri[grid_name], field, transform=transform, **kwargs)
            ax.set_extent(extents, transform)

            if draw_coastlines:
                ax.coastlines(resolution=resolution, linewidth=self.line_width)

            if tick_inc:
                self._add_ticks(ax)

            ax.set_xlabel('Longitude (E)', fontsize=self.font_size)
            ax.set_ylabel('Longitude (N)', fontsize=self.font_size)
        else:
            plot = ax.tripcolor(self.tri, field, **kwargs)
            ax.set_extent(extents)

            ax.set_xlabel('x (m)', fontsize=self.font_size)
            ax.set_ylabel('y (m)', fontsize=self.font_size)

        # Add colour bar
        if add_colour_bar:
            figure = ax.get_figure()
            self._add_colour_bar(figure, ax, plot, cb_label)

        return ax, plot

    def _add_colour_bar(self, figure, axes, plot, cb_label=None):
        # Add colobar scaled to axis width
        divider = make_axes_locatable(axes)
        cax = divider.append_axes("right", size="5%", pad=0.05, axes_class=plt.Axes)
        cbar = figure.colorbar(plot, cax=cax)
        cbar.ax.tick_params(labelsize=self.font_size)
        if cb_label:
            cbar.set_label(cb_label, size=self.font_size)
        return

    def plot_lines(self, ax, x, y, **kwargs):
        """Plot path lines.

        In addition to the listed parameters, the function accepts all keyword arguments taken by the Matplotlib
        plot command.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        x : ND array
            Array of x coordinates to plot.

        y : ND array
            Array of y coordinates to plot.

        Returns:
        --------
        axes : matplotlib.axes.Axes
            Axes object

        line_plot : matplotlib.collections.Line2D
            The plot object
        """
        # Use some better default attributes if they have not been supplied
        alpha = kwargs.pop('alpha', 0.25)
        color = kwargs.pop('color', 'r')
        linewidth = kwargs.pop('linewidth', 1.0)

        line_plots = ax.plot(x, y, zorder=3, alpha=alpha, color=color, linewidth=linewidth, **kwargs)

        return ax, line_plots

    def remove_line_plots(self, line_plots):
        """ Remove line plots

        Useful when updating plots for animations.

        Parameters
        ----------
        line_plots : list
            List of line plot objects created during call to plot_lines()
        """
        while line_plots:
            line_plots.pop(0).remove()

        return

    def scatter(self, ax, grid_name, x, y, configure=False, transform=ccrs.PlateCarree(), zorder=4,
                extents=None, draw_coastlines=False, resolution='10m', tick_inc=False, **kwargs):
        """ Create a scatter plot using the provided x and y values

        If geospatial_coords is True, x and y should be geospatial (lat, lon) coordinates. If not, x any y should
        be given as cartesian coordinates.

        See Matplotlib's scatter documentation for a list of additional key
        word arguments.

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        grid_name : str
            The name of the grid on which the field data is defined

        x : 1D array
            Array of 'x' positions. If plotting in geospatial coords, these should be longitudes.

        y : 1D array
            Array of 'y' positions. If plotting in geospatial coords, these should be latitudes.

        configure : bool, optional
            If true, configure the plot by setting plot extents, drawing coastlines etc. Default: False.

        transform : cartopy.crs.Projection
            The type of transform to perform if geospatial_coords is True. Optional.

        draw_coastlines : bool
            Draw coastlines? Only used if geospatial_coords is True. Optional.

        resolution : str, optional
            Resolution to use when plotting the coastline. Only used when draw_coastline=True. Default: '10m'.

        tick_inc : bool
            Draw ticks? Only used if geospatial_coords is True. Optional.

        Returns
        -------
        ax : matplotlib.axes.Axes
            Axes object

        scatter_plot : matplotlib.collection.PathCollection
            The scatter plot
        """
        # Check to see if a field has already been plotted, indicating we can simply overlay
        # particle positions without setting up the plot in full.
        if not configure:
            if self.geospatial_coords:
                scatter_plot = ax.scatter(x, y, transform=transform, zorder=zorder, **kwargs)
            else:
                scatter_plot = ax.scatter(x, y, zorder=zorder, **kwargs)

            return ax, scatter_plot

        # Create a new plot

        # Set extents
        if extents is None:
            extents = self._get_default_extents(grid_name)

        # Create plot
        if self.geospatial_coords:
            scatter_plot = ax.scatter(x, y, transform=transform, zorder=zorder, **kwargs)
            ax.set_extent(extents, transform)

            if draw_coastlines:
                ax.coastlines(resolution=resolution, linewidth=self.line_width)

            if tick_inc:
                self._add_ticks(ax)
        else:
            scatter_plot = ax.scatter(x, y, zorder=zorder, **kwargs)
            ax.set_extent(extents)

            ax.set_xlabel('x (m)', fontsize=self.font_size)
            ax.set_ylabel('y (m)', fontsize=self.font_size)

        return ax, scatter_plot

    def draw_grid(self, ax, grid_name, draw_masked_elements=False, **kwargs):
        """ Draw the underlying grid or mesh

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        grid_name : str
            The name of the grid on which the field data is defined

        draw_masked_elements : bool
            Include masked elements. Default False.

        Returns
        --------
        ax : matplotlib.axes.Axes
            Axes object
        """
        reinstate_mask = False
        if self.maskc[grid_name] is not None and draw_masked_elements:
            reinstate_mask = True
            self.tri[grid_name].set_mask(None)

        ax.triplot(self.tri[grid_name], zorder=2, **kwargs)

        # Reinstate the mask if needed
        if reinstate_mask:
            self.tri[grid_name].set_mask(self.maskc[grid_name])

    def set_title(self, ax, title):
        """ Set the title

        Parameters
        ----------
        ax : matplotlib.axes.Axes
            Axes object

        title : str
            Plot title
        """
        ax.set_title(title, fontsize=self.font_size)

    #    def get_nodal_coords(self):
    #        return np.copy(self.x), np.copy(self.y)

    def _add_ticks(self, ax):
        gl = ax.gridlines(linewidth=self.line_width, draw_labels=True, linestyle='--', color='k')

        gl.xlabel_style = {'fontsize': self.font_size}
        gl.ylabel_style = {'fontsize': self.font_size}

        gl.xlabels_top = False
        gl.ylabels_right = False
        gl.xlabels_bottom = True
        gl.ylabels_left = True

        gl.xformatter = LONGITUDE_FORMATTER
        gl.yformatter = LATITUDE_FORMATTER


class GOTMPlotter(object):
    """Class to assist in the creation of GOTM plot objects

    Class to assist in the creation of plots and animations based on output
    from the GOTM model, including additional support to plot PyLag outputs.

    Methods
    -------
    time_series : Plot variable through time at a given depth

    profile : Plot depth profile

    hovmoller : pcolormesh plot of a variable on a depth - time grid

    hovmoller_particles : pcolormesh plot of particle concentrations on a depth - time grid

    scatter : scatter plot of particle positions on a depth - time grid

    pathlines : line plot of particle pathlines on a depth - time grid

    Parameters
    ----------
    file_name : str
        File from which to read grid info.

    fs : int, optional
        Font size to use when rendering plot text

    time_rounding : int
        Period between saved data points (in seconds) which is used
        to round datetime objects.
    """
    def __init__(self, file_name, fs=10, time_rounding=None):
        self.file_name = file_name
        self.font_size = fs
        self.time_rounding = time_rounding

        # Initialise the figure
        self.__init_figure()

    def __init_figure(self):
        # Initialise dataset
        self.ds = Dataset(self.file_name, 'r')

        # Times/dates
        self.times = self.ds.variables['time']
        self.dates = num2pydate(self.times[:], units=self.times.units,
                                calendar=self.times.calendar)

        # Time and date bands (for plotting with pcolormesh)
        dt = self.times[1] - self.times[0]
        self.time_bnds = np.empty(self.times.shape[0] + 1, dtype=self.times.dtype)
        self.time_bnds[:-1] = self.times[:] - dt / 2
        self.time_bnds[-1] = self.times[-1] + dt / 2
        self.date_bnds = num2pydate(self.time_bnds[:], units=self.times.units,
                                  calendar=self.times.calendar)

        # Round dates
        if self.time_rounding:
            self.dates = round_time(self.dates, self.time_rounding)
            self.date_bnds = round_time(self.date_bnds, self.time_rounding)

        # Depth at layer centres
        self.z = self.ds.variables['z'][:].squeeze()

        # Depth as layer interfaces
        self.zi = self.ds.variables['zi'][:].squeeze()

        # Layer separations
        self.h = self.ds.variables['h'][:].squeeze()

        # Construct depth and time grids for use with pcolormesh; coordinates
        # should correspond to the points of quadrilaterals surrounding the
        # points where variables are defined. NB the position of the
        # quadrilaterals changes depending on whether the variable is defined at
        # layer interfaces (e.g. turbulence vars) or layer centres (e.g.
        # passive tracers)

        # Compute z bands for plotting with pcolormesh
        self.z_bnds = np.empty((self.z.shape[0] + 1, self.z.shape[1] + 1), dtype=float)
        for i in range(self.z_bnds.shape[1]):
            self.z_bnds[:, i] = interp(self.time_bnds[:], self.times[:], self.zi[:, i])

        # Compute zi bands for plotting with pcolormesh:
        # a) First compute zi_bnds based on the depth of cell centres. Layer
        # thicknesses are used to extrapolate beyond the edge of the grid.
        # b) Next, interpolate these values to time points that are offset by
        # dt/2,
        zi_bnds = np.empty((self.zi.shape[0], self.zi.shape[1] + 1), dtype=float)
        zi_bnds[:, 0] = self.z[:, 0] - self.h[:, 0]
        zi_bnds[:, 1:-1] = self.z[:, :]
        zi_bnds[:, -1] = self.z[:, -1] + self.h[:, -1]
        self.zi_bnds = np.empty((self.zi.shape[0] + 1, self.zi.shape[1] + 1), dtype=float)
        for i in range(self.zi_bnds.shape[1]):
            self.zi_bnds[:, i] = interp(self.time_bnds[:], self.times[:], zi_bnds[:, i])

        # Compute date bands for use with both z_bnds and zi_bnds
        self.date_z_bnds = np.tile(self.date_bnds[:], [self.z_bnds.shape[1], 1]).T
        self.date_zi_bnds = np.tile(self.date_bnds[:], [self.zi_bnds.shape[1], 1]).T

    def time_series(self, axes, var_name, depth, **kwargs):
        """ Make a time series plot

        The function plots a time series of the given variable at the given depth below the free surface.
        GOTM variable data is first interpolated to the given depth.

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object

        var_name : str
            Name of variable to plot.

        depth : float
            Depth relative to the free surface (= 0 m). Positive up.

        Returns
        -------
        axes : matplotlib.axes.Axes
            Axes object
        """
        # Variable data
        var = self.ds.variables[var_name]

        # Interpolate variable data to the given depth below the moving free surface
        var_time_series = []
        for i in range(var.shape[0]):
            depth_offset = depth + self.zi[i, -1]  # Remove offset introduced by the moving free surface

            var_time_series.append(interp(depth_offset, self.z[i, :], var[i, :].squeeze()))

        axes.plot(self.dates, var_time_series, **kwargs)
        axes.set_xlabel('Time', fontsize=self.font_size)
        axes.set_ylabel('{} ({})'.format(var_name, var.units), fontsize=self.font_size)

        return axes

    def profile(self, axes, var_name, date):
        """ Generate a depth profile of the listed variable at the given time point

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object.

        var_name : str
            The variable to plot.

        date : datetime
            The date on which to extract the profile.


        Returns
        -------
        axes : Matplotlib.axes.Axes
            Axes object.
        """
        # Calculate the model time index using a nearest neighbour approach
        t_idx = (np.abs(np.array(self.dates) - date)).argmin()

        var = self.ds.variables[var_name]

        axes.plot(var[t_idx, :, 0, 0].squeeze(), self.z[t_idx, :])

        # Add axis labels
        axes.set_xlabel('{} ({})'.format(var_name, var.units), fontsize=self.font_size)
        axes.set_ylabel('Depth (m)', fontsize=self.font_size)

        return axes

    def hovmoller(self, axes, var_name, add_colorbar=True, cb_label=None, cb_ticks=None, **kwargs):
        """ Draw a hovmoller diagram

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object

        var_name : str
            Name of variable to plot.

        cb_label : str, optional
            The colour bar label.

        cb_ticks : list[float], optional
            Colorbar ticks.

        Returns
        -------
        axes : matplotlib.axes.Axes
            Axes object
        """

        var = self.ds.variables[var_name]

        # Is the variable defined at layer centers or layer interfaces?
        if 'z' in var.dimensions:
            depth_grid = self.z_bnds
            time_grid = self.date_z_bnds
        elif 'zi' in var.dimensions:
            depth_grid = self.zi_bnds
            time_grid = self.date_zi_bnds
        else:
            raise ValueError("Variable `{}` is not depth resolved".format(var_name))

        plot = axes.pcolormesh(time_grid, depth_grid, var[:].squeeze(), **kwargs)

        # Set depth lims
        axes.set_ylim([depth_grid.min(), depth_grid.max()])

        # Add axis labels
        axes.set_xlabel('Time', fontsize=self.font_size)
        axes.set_ylabel('Depth (m)', fontsize=self.font_size)

        # Add colour bar
        if add_colorbar:
            figure = axes.get_figure()
            self.add_colour_bar(figure, axes, plot, cb_label, cb_ticks)

        return axes

    def hovmoller_particles(self, axes, file_names, ds, de, time_rounding, mass_factor=1.0, add_colorbar=True,
                            cb_label=None, cb_ticks=None, **kwargs):
        """ Plot particle concentrations

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object

        file_names : list[str]
            List of sorted PyLag output files. Each output file corresponds to one member
            of the ensemble.

        ds : datetime
            Start datetime.

        de : datetime
            End datetime.

        time_rounding : int
            Period between saved data points (in seconds) which is used to round
            PyLag datetime objects. This option is included to account for cases
            in which PyLag times are written to file with limited precision. Once
            rounded, two datetime objects can be more easily compared. Note this
            parameter may be different to the GOTM time_rounding parameter, which
            is an instance variable.

        mass_factor : float
            Multiplier that is used to generate concentrations from
            probability densities.

        add_colorbar : bool, optional
            Add colorbar?

        cb_label : bool, optional
            Colorbar label.

        cb_ticks : list[float], optional
            Colorbar ticks.
        """
        pylag_viewer = Viewer(file_names[0], time_rounding=time_rounding)

        pylag_first_idx = pylag_viewer.date.tolist().index(ds)
        pylag_last_idx = pylag_viewer.date.tolist().index(de)
        pylag_dates = pylag_viewer.date[pylag_first_idx:pylag_last_idx + 1]

        gotm_first_idx = self.dates.tolist().index(ds)
        gotm_last_idx = self.dates.tolist().index(de)
        gotm_dates = self.dates[gotm_first_idx:gotm_last_idx + 1]

        if not np.array_equal(pylag_dates, gotm_dates):
            raise RuntimeError('PyLag and GOTM date arrays do not match.')

        # Compute particle concentrations
        depths = self.z[gotm_first_idx:gotm_last_idx + 1, :].squeeze()
        depth_bnds = self.zi[gotm_first_idx:gotm_last_idx + 1, (0, -1)].squeeze()
        conc = get_probability_density_1D(file_names, pylag_dates, depths, depth_bnds, time_rounding) * mass_factor

        # Compute date and depth bands for plotting with pcolormesh. The +2
        # accounts for 1) Pyhton slicing rules, and 2) the fact pcolormesh wants
        # the date and z band arrays to be one bigger in size than the
        # concentration array.
        pcol_date_bnds = self.date_z_bnds[gotm_first_idx:gotm_last_idx + 2, :]
        pcol_depth_bnds = self.z_bnds[gotm_first_idx:gotm_last_idx + 2, :]

        # Plot
        plot = axes.pcolormesh(pcol_date_bnds, pcol_depth_bnds, conc, **kwargs)

        # Set depth lims
        axes.set_ylim([pcol_depth_bnds.min(), pcol_depth_bnds.max()])

        # Add axis labels
        axes.set_xlabel('Time', fontsize=self.font_size)
        axes.set_ylabel('Depth (m)', fontsize=self.font_size)

        # Add colour bar
        if add_colorbar:
            figure = axes.get_figure()
            self.add_colour_bar(figure, axes, plot, cb_label, cb_ticks)

        return axes

    def plot_scatter(self, axes, dates, zpos, **kwargs):
        """ Scatter plot of particle positions through time

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object

        dates : array_like
            List of dates

        zpos : array_like
            List of z-positions

        kwargs : dict
            Dictionary of keyword arguments for the scatter plot
        """
        for i in range(zpos.shape[1]):
            axes.scatter(dates, zpos[:, i], **kwargs)

        # Set time and depth lims
        axes.set_xlim([np.min(dates), np.max(dates)])
        axes.set_ylim([np.min(zpos), np.max(zpos)])

    def plot_pathlines(self, axes, dates, zpos, **kwargs):
        """ Plot pathlines through time

        Parameters
        ----------
        axes : matplotlib.axes.Axes
            Axes object

        dates : array_like
            List of dates

        zpos : array_like
            List of zpositions

        kwargs : dict
            Dictionary of keyword arguments for the scatter plot

        Returns
        -------
         : None

        """
        axes.plot(dates, zpos[:, :], **kwargs)

        # Set time and depth lims
        axes.set_xlim([np.min(dates), np.max(dates)])
        axes.set_ylim([np.min(zpos), np.max(zpos)])

        return axes

    def add_colour_bar(self, figure, axes, plot, cb_label, cb_ticks):
        """ Add a colour bar """
        # Add colour bar scaled to axis width
        divider = make_axes_locatable(axes)
        cax = divider.append_axes("right", size="5%", pad=0.05)
        cbar = figure.colorbar(plot, cax=cax, ticks=cb_ticks)
        cbar.ax.tick_params(labelsize=self.font_size)
        cbar.set_label(cb_label)

    def set_title(self, title):
        """ Set title """
        self.axes.set_title(title, fontsize=self.font_size)


def create_figure(figure_size=(10., 10.),  font_size=10, axis_position=None, projection=None, bg_color='white'):
    """ Create a Figure object

    Parameters
    ----------
    figure_size : tuple(float), optional
        Figure size in cm. This is only used if a new Figure object is
        created.

    font_size : int
        Font size to use for axis labels

    axis_position : 1D array, optional
        Array giving axis dimensions

    bg_color : str, optional
        Colour to use for the axis background. Default is `white`. When
        creating a figure for plotting FVCOM outputs, it can be useful
        to set this to `gray`. When FVCOM is fitted to a coastline, the
        gray areas mark the land boundary used by the model. This provides
        a fast alternative to plotting a high resolution (e.g. `res` = `f`)
        land boundary using methods provided by the Basemap class instance.

    """
    figure_size_inches = (cm2inch(figure_size[0]), cm2inch(figure_size[1]))
    figure = plt.figure(figsize=figure_size_inches)
    figure.set_facecolor('white')

    axes = figure.add_subplot(1, 1, 1, projection=projection)

    if axis_position:
        axes.set_position(axis_position)

    axes.tick_params(axis='both', which='major', labelsize=font_size)
    axes.tick_params(axis='both', which='minor', labelsize=font_size)

    if projection is not None:
        axes.background_patch.set_facecolor(bg_color)
    else:
        axes.set_facecolor(bg_color)

    return figure, axes


def create_cbar_ax(ax):
    """Create colorbar axis alligned with plot axis y limits

    Parameters
    ----------
    ax : Axes
        Plot axes instsance

    Returns
    -------
    cax : Axes
        Colorbar plot axis
    """
    divider = make_axes_locatable(ax)
    return divider.append_axes("right", size="5%", pad=0.05)


def colourmap(variable):
    """ Use a predefined colour map for a given variable.

    Leverages the cmocean package for perceptually uniform colour maps.

    Parameters
    ----------
    variable : str, iterable
        For the given variable name(s), return the appropriate colour palette from the cmocean/matplotlib colour maps.
        If the variable is not in the pre-defined variables here, the returned values will be `viridis`.

    Returns
    -------
    colourmaps : matplotlib.colours.cmap, dict
        The colour map(s) for the variable(s) given.

    """

    default_cmap = mpl.cm.get_cmap('viridis')

    cmaps = {'q2': cm.dense,
             'l': cm.dense,
             'q2l': cm.dense,
             'tke': cm.dense,
             'viscofh': cm.dense,
             'kh': cm.dense,
             'nuh': cm.dense,
             'teps': cm.dense,
             'tauc': cm.dense,
             'temp': cm.thermal,
             'sst': cm.thermal,
             'salinity': cm.haline,
             'zeta': cm.balance,
             'ww': cm.balance,
             'omega': cm.balance,
             'uv': cm.speed,
             'uava': cm.speed,
             'speed': cm.speed,
             'u': cm.delta,
             'v': cm.delta,
             'ua': cm.delta,
             'va': cm.delta,
             'uvanomaly': cm.delta,
             'direction': cm.phase,
             'uvdir': cm.phase,
             'h_morpho': cm.deep,
             'h': cm.deep,
             'h_r': cm.deep_r,
             'bathymetry': cm.deep,
             'bathymetry_r': cm.deep_r,
             'taub_total': cm.thermal,
             'mud_1': cm.turbid,
             'mud_2': cm.turbid,
             'sand_1': cm.turbid,
             'sand_2': cm.turbid,
             'todal_ssc': cm.turbid,
             'total_ssc': cm.turbid,
             'mud_1_bedfrac': cm.dense,
             'mud_2_bedfrac': cm.dense,
             'sand_1_bedfrac': cm.dense,
             'sand_2_bedfrac': cm.dense,
             'mud_1_bedload': cm.dense,
             'mud_2_bedload': cm.dense,
             'sand_1_bedload': cm.dense,
             'sand_2_bedload': cm.dense,
             'bed_thick': cm.deep,
             'bed_age': cm.tempo,
             'bed_por': cm.turbid,
             'bed_diff': cm.haline,
             'bed_btcr': cm.thermal,
             'bot_sd50': cm.turbid,
             'bot_dens': cm.thermal,
             'bot_wsed': cm.turbid,
             'bot_nthck': cm.matter,
             'bot_lthck': cm.matter,
             'bot_dthck': cm.matter,
             'bot_morph': cm.deep,
             'bot_tauc': cm.thermal,
             'bot_rlen': cm.dense,
             'bot_rhgt': cm.dense,
             'bot_bwav': cm.turbid,
             'bot_zdef': cm.dense,
             'bot_zapp': cm.dense,
             'bot_zNik': cm.dense,
             'bot_zbio': cm.dense,
             'bot_zbfm': cm.dense,
             'bot_zbld': cm.dense,
             'bot_zwbl': cm.dense,
             'bot_actv': cm.deep,
             'bot_shgt': cm.deep_r,
             'bot_maxD': cm.deep,
             'bot_dnet': cm.matter,
             'bot_doff': cm.thermal,
             'bot_dslp': cm.amp,
             'bot_dtim': cm.haline,
             'bot_dbmx': cm.dense,
             'bot_dbmm': cm.dense,
             'bot_dbzs': cm.dense,
             'bot_dbzm': cm.dense,
             'bot_dbzp': cm.dense,
             'wet_nodes': cm.amp,
             'tracer1_c': cm.dense,
             'DYE': cm.dense}

    if isinstance(variable, collections.Iterable) and not isinstance(variable, str):
        colourmaps = []
        for var in variable:
            if var in cmaps:
                colourmaps.append(cmaps[var])
            else:
                colourmaps.append(default_cmap)
        # If we got a list of a single value, return the value rather than a list.
        if len(colourmaps) == 1:
            colourmaps = colourmaps[0]
    else:
        if variable in cmaps:
            colourmaps = cmaps[variable]
        else:
            colourmaps = default_cmap

    return colourmaps
