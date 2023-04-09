# This file is part of pncpy, a Python interface to the PnetCDF library.
#
#
# Copyright (C) 2023, Northwestern University
# See COPYRIGHT notice in top-level directory
# License:  

"""
   This example program is intended to illustrate the use of the pnetCDF python API.The 
   program runs in blocking mode and read an subsampled array of values from a netCDF 
   variable of an opened netCDF file using iget_var method of `Variable` class. The 
   library will internally invoke ncmpi_get_vars in C. 
"""
import pncpy
from numpy.random import seed, randint
from numpy.testing import assert_array_equal, assert_equal, assert_array_almost_equal
import tempfile, unittest, os, random, sys
import numpy as np
from mpi4py import MPI
from utils import validate_nc_file

seed(0)
data_models = ['64BIT_DATA', '64BIT_OFFSET', None]
file_name = "tst_var_get_vars.nc"


comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
xdim=9; ydim=10; zdim=size*10
# initial values for netCDF variable
data = randint(0,10, size=(xdim,ydim,zdim)).astype('i4')
# generate reference dataframes for testing
dataref = []
for i in range(size):
    dataref.append(data[3:4:1,0:6:2,i*10:(i+1)*10:2])

class VariablesTestCase(unittest.TestCase):

    def setUp(self):
        if (len(sys.argv) == 2) and os.path.isdir(sys.argv[1]):
            self.file_path = os.path.join(sys.argv[1], file_name)
        else:
            self.file_path = file_name
        data_model = data_models.pop(0)
        f = pncpy.File(filename=self.file_path, mode = 'w', format=data_model, Comm=comm, Info=None)
        f.defineDim('x',xdim)
        f.defineDim('xu',-1)
        f.defineDim('y',ydim)
        f.defineDim('z',zdim)

        v1_u = f.defineVar('data1u', pncpy.NC_INT, ('xu','y','z'))

        #initialize variable values
        f.enddef()
        v1_u[:] = data
        f.close()
        assert validate_nc_file(self.file_path) == 0

    def test_cdf5(self):
        """testing variable get_vars method for CDF-5 file format"""

        f = pncpy.File(self.file_path, 'r')
        starts = np.array([3,0,10*rank])
        counts = np.array([1,3,5])
        strides = np.array([1,2,2])
        # test collective i/o get_var
        f.enddef()
        v1 = f.variables['data1u']
        # all processes read the designated slices of the variable using collective i/o
        v1_data = v1.get_var_all(start = starts, count = counts, stride = strides)
        # compare returned numpy array against reference array
        assert_array_equal(v1_data, dataref[rank])
        # test independent i/o get_var
        f.begin_indep()
        if rank < 2:
            # mpi process rank 0 and rank 1 respectively read the assigned slice of the variable using independent i/o
            v1_data_indep = v1.get_var(start = starts, count = counts, stride = strides)
            # compare returned numpy array against reference array
            assert_array_equal(v1_data_indep, dataref[rank])
        f.close()

    def test_cdf2(self):
        """testing variable get_vars method for CDF-2 file format"""
        f = pncpy.File(self.file_path, 'r')
        starts = np.array([3,0,10*rank])
        counts = np.array([1,3,5])
        strides = np.array([1,2,2])
        # test collective i/o get_var
        f.enddef()
        v1 = f.variables['data1u']
        # all processes read the designated slices of the variable using collective i/o
        v1_data = v1.get_var_all(start = starts, count = counts, stride = strides)
        # compare returned numpy array against reference array
        assert_array_equal(v1_data, dataref[rank])
        # test independent i/o get_var
        f.begin_indep()
        if rank < 2:
            # mpi process rank 0 and rank 1 respectively read the assigned slice of the variable using independent i/o
            v1_data_indep = v1.get_var(start = starts, count = counts, stride = strides)
            # compare returned numpy array against reference array
            assert_array_equal(v1_data_indep, dataref[rank])
        f.close()

    def test_cdf1(self):
        """testing variable get_vars method for CDF-1 file format"""
        f = pncpy.File(self.file_path, 'r')
        starts = np.array([3,0,10*rank])
        counts = np.array([1,3,5])
        strides = np.array([1,2,2])
        # test collective i/o get_var
        f.enddef()
        v1 = f.variables['data1u']
        # all processes read the designated slices of the variable using collective i/o
        v1_data = v1.get_var_all(start = starts, count = counts, stride = strides)
        # compare returned numpy array against reference array
        assert_array_equal(v1_data, dataref[rank])
        # test independent i/o get_var
        f.begin_indep()
        if rank < 2:
            # mpi process rank 0 and rank 1 respectively read the assigned slice of the variable using independent i/o
            v1_data_indep = v1.get_var(start = starts, count = counts, stride = strides)
            # compare returned numpy array against reference array
            assert_array_equal(v1_data_indep, dataref[rank])
        f.close()

    def tearDown(self):
        # remove the temporary files if test file directory not specified
        comm.Barrier()
        if (rank == 0) and not((len(sys.argv) == 2) and os.path.isdir(sys.argv[1])):
            os.remove(self.file_path)

if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])