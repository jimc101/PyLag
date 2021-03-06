"""
Module containing factory method for Model Objects
"""

from pylag.model import OPTModel
from pylag.arakawa_a_data_reader import ArakawaADataReader
from pylag.fvcom_data_reader import FVCOMDataReader
from pylag.roms_data_reader import ROMSDataReader
from pylag.gotm_data_reader import GOTMDataReader

# Parallel imports
from pylag.parallel.mediator import MPIMediator


def get_model(config, datetime_start, datetime_end):
    """ Factory method for model objects

    Parameters
    ----------
    config : ConfigParser
        Configuration object

    datetime_start : Datetime
        Start datetime

    datetime_end : Datetime
        End datetime

    Returns
    -------
     : pylag.model.OPTModel
         Offline particle tracking model object
    """
    if config.get("OCEAN_CIRCULATION_MODEL", "name") == "ArakawaA":
        mediator = MPIMediator(config, datetime_start, datetime_end)
        data_reader = ArakawaADataReader(config, mediator)
        return OPTModel(config, data_reader)
    elif config.get("OCEAN_CIRCULATION_MODEL", "name") == "FVCOM":
        mediator = MPIMediator(config, datetime_start, datetime_end)
        data_reader = FVCOMDataReader(config, mediator)
        return OPTModel(config, data_reader)
    elif config.get("OCEAN_CIRCULATION_MODEL", "name") == "ROMS":
        mediator = MPIMediator(config, datetime_start, datetime_end)
        data_reader = ROMSDataReader(config, mediator)
        return OPTModel(config, data_reader)
    elif config.get("OCEAN_CIRCULATION_MODEL", "name") == "GOTM":
        mediator = MPIMediator(config, datetime_start, datetime_end)
        data_reader = GOTMDataReader(config, mediator)
        return OPTModel(config, data_reader)
    else:
        raise ValueError('Unsupported ocean circulation model.')

__all__ = ['get_model']
