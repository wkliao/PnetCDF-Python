# This file is part of pncpy, a Python interface to the PnetCDF library.
#
#
# Copyright (C) 2023, Northwestern University
# See COPYRIGHT notice in top-level directory
# License:  

"""
   This example program is intended to illustrate the use of the pnetCDF python API.
   The program runs in non-blocking mode and makes a request to write all the values of a variable 
   into a netCDF variable of an opened netCDF file using iput_var method of `Variable` class. The 
   library will internally invoke ncmpi_iput_var in C. 
"""
import pncpy
from numpy.random import seed, randint
from numpy.testing import assert_array_equal, assert_equal,\
assert_array_almost_equal
import tempfile, unittest, os, random, sys
import numpy as np
from mpi4py import MPI
from pncpy import strerror, strerrno
from utils import validate_nc_file

seed(0)
data_models = ['64BIT_DATA', '64BIT_OFFSET', None]
file_name = "tst_var_iput_var.nc"
xdim=9; ydim=10; zdim=11
data = randint(0,10, size=(xdim,ydim,zdim)).astype('i4')


comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
num_reqs = 10

class VariablesTestCase(unittest.TestCase):

    def setUp(self):
        if (len(sys.argv) == 2) and os.path.isdir(sys.argv[1]):
            self.file_path = os.path.join(sys.argv[1], file_name)
        else:
            self.file_path = file_name
        data_model = data_models.pop(0)
        f = pncpy.File(filename=self.file_path, mode = 'w', format=data_model, Comm=comm, Info=None)
        f.defineDim('x',xdim)
        f.defineDim('y',ydim)
        f.defineDim('z',zdim)
        # define 10 netCDF variables
        for i in range(10):
            v = f.defineVar(f'data{i}', pncpy.NC_INT, ('x','y','z'))

        # post 10 requests to write the whole variable 
        f.enddef()
        req_ids = []
        for i in range(num_reqs):
            v = f.variables[f'data{i}']
            # post the request to write the whole variable 
            req_id = v.iput_var(data)
            # track the reqeust ID for each write reqeust 
            req_ids.append(req_id)
        f.end_indep()
        # all processes commit the first 5 requests to the file at once using wait_all (collective i/o)
        req_errs = f.wait_all(num_reqs, req_ids)
        comm.Barrier()
        # check request error msg for each unsuccessful requests
        for i in range(num_reqs):
            if strerrno(req_errs[i]) != "NC_NOERR":
                print(f"Error on request {i}:",  strerror(req_errs[i]))
        f.close()
        comm.Barrier()
        assert validate_nc_file(self.file_path) == 0
    
    def tearDown(self):
        # remove the temporary files
        comm.Barrier()
        if (rank == 0) and not((len(sys.argv) == 2) and os.path.isdir(sys.argv[1])):
            os.remove(self.file_path)

    def test_cdf5(self):
        """testing variable iput var all for CDF-5 file format"""

        f = pncpy.File(self.file_path, 'r')
        # test iput_var and collective i/o wait_all
        for i in range(num_reqs):
            v = f.variables[f'data{i}']
            assert_array_equal(v[:], data)

    def test_cdf2(self):
        """testing variable iput var all for CDF-2 file format"""

        f = pncpy.File(self.file_path, 'r')
        # test iput_var and collective i/o wait_all
        for i in range(num_reqs):
            v = f.variables[f'data{i}']
            assert_array_equal(v[:], data)

    def test_cdf(self):
        """testing variable iput var all for CDF-1 file format"""

        f = pncpy.File(self.file_path, 'r')
        # test iput_var and collective i/o wait_all
        for i in range(num_reqs):
            v = f.variables[f'data{i}']
            assert_array_equal(v[:], data)


    # def test_cdf2(self):
    #     """testing variable put var all"""
    #     f = pncpy.File(self.file_path, 'r')
    #     # test collective i/o put_var1
    #     f.enddef()
    #     v1 = f.variables['data1']
    #     assert_array_equal(v1[:], data)
    #     # test independent i/o put_var1
    #     v2 = f.variables['data2']
    #     assert_array_equal(v2[:], datarev)
    #     f.close()

    # def test_cdf1(self):
    #     """testing variable put var all"""
    #     f = pncpy.File(self.file_path, 'r')
    #     # test collective i/o put_var1
    #     f.enddef()
    #     v1 = f.variables['data1']
    #     assert_array_equal(v1[:], data)
    #     # test independent i/o put_var1
    #     v2 = f.variables['data2']
    #     assert_array_equal(v2[:], datarev)
    #     f.close()



if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])