from unittest import TestCase
import numpy.testing as test

from pylag.data_reader import DataReader
from pylag.boundary_conditions import RefHorizBoundaryConditionCalculator

class RefHorizBoundaryConditionCalculator_test(TestCase):
    class TestDataReader(DataReader):
        def get_boundary_intersection(self, xpos_old, ypos_old, xpos_new, ypos_new, elem):
            x1 = -1.0; y1 = -1.0; x2 = 1.0; y2 = 1.0; xi=0.0; yi=0.0
            return x1, y1, x2, y2, xi, yi

    def test_apply_reflecting_boundary_condition(self):
        data_reader = RefHorizBoundaryConditionCalculator_test.TestDataReader()
        horiz_bc_calculator = RefHorizBoundaryConditionCalculator()
        x3 = 0.0; y3 = -1.0; x4 = 0.0; y4 = 1.0; elem = 0
        xpos, ypos = horiz_bc_calculator.apply(data_reader, x3, y3, x4, y4, elem)
        test.assert_almost_equal(xpos, 1.0)
        test.assert_almost_equal(ypos, 0.0)

