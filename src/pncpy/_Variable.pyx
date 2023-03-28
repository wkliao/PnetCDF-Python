import sys
import os
import subprocess
import numpy as np
import warnings
include "PnetCDF.pxi"

import mpi4py.MPI as MPI
from mpi4py.libmpi cimport MPI_Comm, MPI_Info, MPI_Comm_dup, MPI_Info_dup, \
                               MPI_Comm_free, MPI_Info_free, MPI_INFO_NULL,\
                               MPI_COMM_WORLD, MPI_Offset, MPI_DATATYPE_NULL
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy, memset
from ._Dimension cimport Dimension
from ._utils cimport _strencode, _check_err, _set_att, _get_att, _get_att_names, _tostr, _safecast, chartostring, stringtochar
from ._utils cimport _nptonctype, _notcdf2dtypes, _nctonptype, _nptompitype, _supportedtypes, _supportedtypescdf2, \
                     default_fillvals, _StartCountStride, _out_array_shape
import_array()
_private_atts = \
['_ncid','_varid','dimensions','variables','data_model','disk_format',
 '_nunlimdim','path', 'name', '__orthogoral_indexing__', '_buffer']



cdef class Variable:
    """
    A PnetCDF `Variable` is used to read and write netCDF data.  They are
    analogous to numpy array objects. See `Variable.__init__` for more
    details.

    A list of attribute names corresponding to netCDF attributes defined for
    the variable can be obtained with the `Variable.ncattrs` method. These
    attributes can be created by assigning to an attribute of the
    `Variable` instance. A dictionary containing all the netCDF attribute
    name/value pairs is provided by the `__dict__` attribute of a
    `Variable` instance.

    The following class variables are read-only:

    **`dimensions`**: A tuple containing the names of the
    dimensions associated with this variable.

    **`dtype`**: A numpy dtype object describing the
    variable's data type.

    **`ndim`**: The number of variable dimensions.

    **`shape`**: A tuple with the current shape (length of all dimensions).

    **`scale`**: If True, `scale_factor` and `add_offset` are
    applied, and signed integer data is automatically converted to
    unsigned integer data if the `_Unsigned` attribute is set.
    Default is `True`, can be reset using `Variable.set_auto_scale` and
    `Variable.set_auto_maskandscale` methods.

    **`mask`**: If True, data is automatically converted to/from masked
    arrays when missing values or fill values are present. Default is `True`, can be
    reset using `Variable.set_auto_mask` and `Variable.set_auto_maskandscale`
    methods. Only relevant for Variables with primitive or enum types (ignored
    for compound and vlen Variables).

    **`chartostring`**: If True, data is automatically converted to/from character
    arrays to string arrays when the `_Encoding` variable attribute is set.
    Default is `True`, can be reset using
    `Variable.set_auto_chartostring` method.

    **`least_significant_digit`**: Describes the power of ten of the
    smallest decimal place in the data the contains a reliable value.  Data is
    truncated to this decimal place when it is assigned to the `Variable`
    instance. If `None`, the data is not truncated.

    **`__orthogonal_indexing__`**: Always `True`.  Indicates to client code
    that the object supports 'orthogonal indexing', which means that slices
    that are 1d arrays or lists slice along each dimension independently.  This
    behavior is similar to Fortran or Matlab, but different than np.

    **`datatype`**: numpy data type (for primitive data types) or VLType/CompoundType
    instance (for compound or vlen data types).

    **`name`**: String name.

    **`size`**: The number of stored elements.
    """

    def __init__(self, file, name, nc_dtype, dimensions=(), fill_value=False, **kwargs):
        """
        **`__init__(self, file, name, datatype, dimensions=(),
            endian='native', least_significant_digit=None,
            significant_digits=None, fill_value=None, **kwargs)`**

        `Variable` constructor.

        **`group`**: `Group` or `Dataset` instance to associate with variable.

        **`name`**: Name of the variable.

        **`datatype`**: `Variable` data type. Can be specified by providing a
        numpy dtype object, or a string that describes a numpy dtype object.
        Supported values, corresponding to `str` attribute of numpy dtype
        objects, include `'f4'` (32-bit floating point), `'f8'` (64-bit floating
        point), `'i4'` (32-bit signed integer), `'i2'` (16-bit signed integer),
        `'i8'` (64-bit signed integer), `'i4'` (8-bit signed integer), `'i1'`
        (8-bit signed integer), `'u1'` (8-bit unsigned integer), `'u2'` (16-bit
        unsigned integer), `'u4'` (32-bit unsigned integer), `'u8'` (64-bit
        unsigned integer), or `'S1'` (single-character string).

        **`dimensions`**: a tuple containing the variable's Dimension instances
        (defined previously with `defineDim`). Default is an empty tuple
        which means the variable is a scalar (and therefore has no dimensions).

        **`least_significant_digit`**: If this or `significant_digits` are specified,
        variable data will be truncated (quantized).
        In conjunction with `compression='zlib'` this produces
        'lossy', but significantly more efficient compression. For example, if
        `least_significant_digit=1`, data will be quantized using
        around(scale*data)/scale, where scale = 2**bits, and bits is determined
        so that a precision of 0.1 is retained (in this case bits=4). Default is
        `None`, or no quantization.

        **`significant_digits`**: New in version 1.6.0.
        As described for `least_significant_digit`
        except the number of significant digits retained is prescribed independent
        of the floating point exponent. Default `None` - no quantization done.

        **`fill_value`**:  If specified, the default netCDF `_FillValue` (the
        value that the variable gets filled with before any data is written to it)
        is replaced with this value.  If fill_value is set to `False`, then
        the variable is not pre-filled. 

        ***Note***: `Variable` instances should be created using the
        `File.defineVar` method of a `File` instance, not using this class directly.
        """

        cdef int ierr, ndims, icontiguous, icomplevel, numdims, _file_id, nsd,
        cdef char namstring[NC_MAX_NAME+1]
        cdef char *varname
        cdef nc_type xtype
        cdef int *dimids
        cdef size_t sizep, nelemsp
        cdef size_t *chunksizesp
        cdef float preemptionp
        self._file_id = file._ncid
        # TODO: decide whether to keep weakref feature
        """        
        if file.keepweakref:
            self._file = weakref.proxy(file)
        else:
            self._file = file
        """
        self._file = file
        _file_id = self._file_id
        #TODO: decide whether we need to check xtype at python-level
        xtype = nc_dtype
        self.xtype = xtype
        self.dtype = np.dtype(_nctonptype[xtype])


        if 'id' in kwargs:
            self._varid = kwargs['id']
        else:
            bytestr = _strencode(name)
            varname = bytestr
            ndims = len(dimensions)
            # find dimension ids.
            if ndims:
                dimids = <int *>malloc(sizeof(int) * ndims)
                for n from 0 <= n < ndims:
                    dimids[n] = dimensions[n]._dimid
            need_open_def = not (file.def_mode_on)
            if need_open_def: file.redef() 
            if ndims:
                with nogil:
                    ierr = ncmpi_def_var(_file_id, varname, xtype, ndims,
                                    dimids, &self._varid)
                free(dimids)
            else: # a scalar variable.
                with nogil:
                    ierr = ncmpi_def_var(_file_id, varname, xtype, ndims,
                                    NULL, &self._varid)
            if need_open_def: file.enddef()
            if ierr != NC_NOERR:
                _check_err(ierr)
            #xtype compatability already veried by C function, no need to check at python level
            if fill_value is not None:
                if not fill_value and isinstance(fill_value,bool):
                    # no filling for this variable if fill_value==False.
                    need_open_def = not (file.def_mode_on)
                    if need_open_def: file.redef() 
                    with nogil:
                        ierr = ncmpi_def_var_fill(_file_id, self._varid, 1, NULL)
                    if need_open_def: file.enddef()
                    if ierr != NC_NOERR:
                        _check_err(ierr)
                else:
                    fillval = np.array(fill_value, self.dtype)
                    if not fillval.dtype.isnative: 
                        fillval.byteswap(True)
                    need_open_def = not (file.def_mode_on)
                    if need_open_def: file.redef() 
                    _set_att(self._file, self._varid, '_FillValue',\
                                fillval, xtype=xtype)
                    if need_open_def: file.enddef()


        # count how many unlimited dimensions there are.
        self._nunlimdim = 0
        for dim in dimensions:
            if dim.isunlimited(): self._nunlimdim = self._nunlimdim + 1
        # set ndim attribute (number of dimensions).
        with nogil:
            ierr = ncmpi_inq_varndims(_file_id, self._varid, &numdims)
        _check_err(ierr)
        self.ndim = numdims
        self._name = name
        # default for automatically applying scale_factor and
        # add_offset, and converting to/from masked arrays is True.
        self.scale = True
        self.mask = True
        # issue 809: default for converting arrays with no missing values to
        # regular numpy arrays
        self.always_mask = True
        # default is to automatically convert to/from character
        # to string arrays when _Encoding variable attribute is set.
        self.chartostring = True
        # propagate _ncstring_attrs__ setting from parent group.
        if 'least_significant_digit' in self.ncattrs():
            self._has_lsd = True

    def __array__(self):
        # numpy special method that returns a numpy array.
        # allows numpy ufuncs to work faster on Variable objects
        # (issue 216).
        return self[...]

    def __repr__(self):
        return self.__str__()

    def __str__(self):
        cdef int ierr, no_fill
        ncdump = [repr(type(self))]
        show_more_dtype = True
        kind = str(self.dtype)
        dimnames = tuple(_tostr(dimname) for dimname in self.dimensions)
        ncdump.append('%s %s(%s)' %\
            (kind, self._name, ', '.join(dimnames)))
        for name in self.ncattrs():
            ncdump.append('    %s: %s' % (name, self.getncattr(name)))
        if show_more_dtype:
            ncdump.append('%s data type: %s' % (kind, self.dtype))
        unlimdims = []
        for dimname in self.dimensions:
            dim = self._file.dimensions[dimname]
            if dim.isunlimited():
                unlimdims.append(dimname)

        ncdump.append('unlimited dimensions: %s' % ', '.join(unlimdims))
        ncdump.append('current shape = %r' % (self.shape,))

        with nogil:
            ierr = ncmpi_inq_var_fill(self._file_id,self._varid,&no_fill,NULL)
        _check_err(ierr)

        if no_fill != 1:
            try:
                fillval = self._FillValue
                msg = 'filling on'
            except AttributeError:
                fillval = default_fillvals[self.dtype.str[1:]]
                if self.dtype.str[1:] in ['u1','i1']:
                    msg = 'filling on, default _FillValue of %s ignored' % fillval
                else:
                    msg = 'filling on, default _FillValue of %s used' % fillval
            ncdump.append(msg)
        else:
            ncdump.append('filling off')
        return '\n'.join(ncdump)

    def _getdims(self):
        # Private method to get variables's dimension names
        cdef int ierr, numdims, n, nn
        cdef char namstring[NC_MAX_NAME+1]
        cdef int *dimids
        # get number of dimensions for this variable.
        with nogil:
            ierr = ncmpi_inq_varndims(self._file_id, self._varid, &numdims)
        _check_err(ierr)
        dimids = <int *>malloc(sizeof(int) * numdims)
        # get dimension ids.
        with nogil:
            ierr = ncmpi_inq_vardimid(self._file_id, self._varid, dimids)
        _check_err(ierr)
        # loop over dimensions, retrieve names.
        dimensions = ()
        for nn from 0 <= nn < numdims:
            with nogil:
                ierr = ncmpi_inq_dimname(self._file_id, dimids[nn], namstring)
            _check_err(ierr)
            name = namstring.decode('utf-8')
            dimensions = dimensions + (name,)
        free(dimids)
        return dimensions

    def _getname(self):
        # Private method to get name associated with instance
        cdef int err, _file_id
        cdef char namstring[NC_MAX_NAME+1]
        _file_id = self._file._ncid
        with nogil:
            ierr = ncmpi_inq_varname(_file_id, self._varid, namstring)
        _check_err(ierr)
        return namstring.decode('utf-8')
    property name:
        """string name of Variable instance"""
        def __get__(self):
            return self._getname()
        def __set__(self,value):
            raise AttributeError("name cannot be altered")

    property datatype:
        """numpy data type"""
        def __get__(self):
            return self.dtype
    """
    property shape:
        pass #TODO: implement this!
    """
    property shape:
        """find current sizes of all variable dimensions"""
        def __get__(self):
            shape = ()
            for dimname in self._getdims():
                # look in current group, and parents for dim.
                dim = self._file.dimensions[dimname]
                shape = shape + (len(dim),)
            return shape
        def __set__(self,value):
            raise AttributeError("shape cannot be altered")

    property size:
        """Return the number of stored elements."""
        def __get__(self):
            return int(np.prod(self.shape))

    property dimensions:
        """get variables's dimension names"""
        def __get__(self):
            return self._getdims()
        def __set__(self,value):
            raise AttributeError("dimensions cannot be altered")
    def file(self):
        return self._file
    def ncattrs(self):
        """
        **`ncattrs(self)`**

        return netCDF attribute names for this `Variable` in a list."""
        return _get_att_names(self._file_id, self._varid)
    def setncattr(self,name,value):
        """
        **`setncattr(self,name,value)`**

        set a netCDF variable attribute using name,value pair.  Use if you need to set a
        netCDF attribute with the same name as one of the reserved python
        attributes."""
        cdef nc_type xtype
        xtype=-99
        if name == '_FillValue':
            msg='_FillValue attribute must be set when variable is '+\
            'created (using fill_value keyword to defineVar)'
            raise AttributeError(msg)
        need_open_def = not (self._file.def_mode_on)
        if need_open_def: self._file.redef()
        _set_att(self._file, self._varid, name, value, xtype=xtype)
        if need_open_def: self._file.enddef()

    def setncatts(self,attdict):
        """
        **`setncatts(self,attdict)`**

        set a bunch of netCDF variable attributes at once using a python dictionary.
        This may be faster when setting a lot of attributes for a `NETCDF3`
        formatted file, since nc_redef/nc_enddef is not called in between setting
        each attribute"""
        need_open_def = not (self._file.def_mode_on)
        if need_open_def: self._file.redef()
        for name, value in attdict.items():
            _set_att(self._file, self._varid, name, value)
        if need_open_def: self._file.enddef()

    def getncattr(self,name,encoding='utf-8'):
        """
        **`getncattr(self,name)`**

        retrieve a netCDF variable attribute.  Use if you need to set a
        netCDF attribute with the same name as one of the reserved python
        attributes.

        option kwarg `encoding` can be used to specify the
        character encoding of a string attribute (default is `utf-8`)."""
        return _get_att(self._file, self._file_id, name, encoding=encoding)

    def delncattr(self, name):
        """
        **`delncattr(self,name,value)`**

        delete a netCDF variable attribute.  Use if you need to delete a
        netCDF attribute with the same name as one of the reserved python
        attributes."""
        cdef char *attname
        bytestr = _strencode(name)
        attname = bytestr
        need_open_def = not (self._file.def_mode_on)
        if need_open_def: self._file.redef()
        with nogil:
            ierr = ncmpi_del_att(self._file_id, self._varid, attname)
        if need_open_def: self._file.enddef()
        _check_err(ierr)

    def __delattr__(self,name):
        # if it's a netCDF attribute, remove it
        if name not in _private_atts:
            self.delncattr(name)
        else:
            raise AttributeError(
            "'%s' is one of the reserved attributes %s, cannot delete. Use delncattr instead." % (name, tuple(_private_atts)))
    
    def __setattr__(self,name,value):
        # if name in _private_atts, it is stored at the python
        # level and not in the netCDF file.
        if name not in _private_atts:
            # if setting _FillValue or missing_value, make sure value
            # has same type and byte order as variable.
            if name == '_FillValue':
                msg='_FillValue attribute must be set when variable is '+\
                'created (using fill_value keyword to defineVar)'
                raise AttributeError(msg)
            elif name in ['valid_min','valid_max','valid_range','missing_value']:
                # make sure these attributes written in same data type as variable.
                # also make sure it is written in native byte order
                # (the same as the data)
                valuea = np.array(value, self.dtype)
                # check to see if array cast is safe
                if _safecast(np.array(value),valuea):
                    value = valuea
                    if not value.dtype.isnative: value.byteswap(True)
                else: # otherwise don't do it, but issue a warning
                    msg="WARNING: %s cannot be safely cast to variable dtype" \
                    % name
                    warnings.warn(msg)
            self.setncattr(name, value)
        elif not name.endswith('__'):
            if hasattr(self,name):
                raise AttributeError(
                "'%s' is one of the reserved attributes %s, cannot rebind. Use setncattr instead." % (name, tuple(_private_atts)))
            else:
                self.__dict__[name]=value

    def __getattr__(self,name):
        # if name in _private_atts, it is stored at the python
        # level and not in the netCDF file.
        if name.startswith('__') and name.endswith('__'):
            # if __dict__ requested, return a dict with netCDF attributes.
            if name == '__dict__':
                names = self.ncattrs()
                values = []
                for name in names:
                    values.append(_get_att(self._file, self._varid, name))
                return dict(zip(names, values))

            else:
                raise AttributeError
        elif name in _private_atts:
            return self.__dict__[name]
        else:
            return self.getncattr(name)

    def renameAttribute(self, oldname, newname):
        """
        **`renameAttribute(self, oldname, newname)`**

        rename a `Variable` attribute named `oldname` to `newname`."""
        cdef char *oldnamec
        cdef char *newnamec
        cdef int ierr
        bytestr = _strencode(oldname)
        oldnamec = bytestr
        bytestr = _strencode(newname)
        newnamec = bytestr
        with nogil:
            ierr = ncmpi_rename_att(self._file_id, self._varid, oldnamec, newnamec)
        _check_err(ierr)

    def get_dims(self):
        """
        **`get_dims(self)`**

        return a tuple of `Dimension` instances associated with this
        `Variable`.
                """
        return tuple(self._file.dimensions[dim] for dim in self.dimensions)

    def assignValue(self,val):
        """
        **`assignValue(self, val)`**

        assign a value to a scalar variable.  Provided for compatibility with
        Scientific.IO.NetCDF, can also be done by assigning to an Ellipsis slice ([...])."""
        if len(self.dimensions):
            raise IndexError('to assign values to a non-scalar variable, use a slice')
        self[:]=val

    def getValue(self):
        """
        **`getValue(self)`**

        get the value of a scalar variable.  Provided for compatibility with
        Scientific.IO.NetCDF, can also be done by slicing with an Ellipsis ([...])."""
        if len(self.dimensions):
            raise IndexError('to retrieve values from a non-scalar variable, use slicing')
        return self[slice(None)]

    def set_auto_chartostring(self,chartostring):
        """
        **`set_auto_chartostring(self,chartostring)`**

        turn on or off automatic conversion of character variable data to and
        from numpy fixed length string arrays when the `_Encoding` variable attribute
        is set.

        If `chartostring` is set to `True`, when data is read from a character variable
        (dtype = `S1`) that has an `_Encoding` attribute, it is converted to a numpy
        fixed length unicode string array (dtype = `UN`, where `N` is the length
        of the the rightmost dimension of the variable).  The value of `_Encoding`
        is the unicode encoding that is used to decode the bytes into strings.

        When numpy string data is written to a variable it is converted back to
        indiviual bytes, with the number of bytes in each string equalling the
        rightmost dimension of the variable.

        The default value of `chartostring` is `True`
        (automatic conversions are performed).
        """
        self.chartostring = bool(chartostring)

    def set_auto_scale(self,scale):
        """
        **`set_auto_scale(self,scale)`**

        turn on or off automatic packing/unpacking of variable
        data using `scale_factor` and `add_offset` attributes.
        Also turns on and off automatic conversion of signed integer data
        to unsigned integer data if the variable has an `_Unsigned`
        attribute.

        If `scale` is set to `True`, and the variable has a
        `scale_factor` or an `add_offset` attribute, then data read
        from that variable is unpacked using::

            data = self.scale_factor*data + self.add_offset

        When data is written to a variable it is packed using::

            data = (data - self.add_offset)/self.scale_factor

        If either scale_factor is present, but add_offset is missing, add_offset
        is assumed zero.  If add_offset is present, but scale_factor is missing,
        scale_factor is assumed to be one.
        For more information on how `scale_factor` and `add_offset` can be
        used to provide simple compression, see the
        [PSL metadata conventions](http://www.esrl.noaa.gov/psl/data/gridded/conventions/cdc_netcdf_standard.shtml).

        In addition, if `scale` is set to `True`, and if the variable has an
        attribute `_Unsigned` set, and the variable has a signed integer data type,
        a view to the data is returned with the corresponding unsigned integer datatype.
        This convention is used by the netcdf-java library to save unsigned integer
        data in `NETCDF3` or `NETCDF4_CLASSIC` files (since the `NETCDF3`
        data model does not have unsigned integer data types).

        The default value of `scale` is `True`
        (automatic conversions are performed).
        """
        self.scale = bool(scale)


    def set_auto_mask(self,mask):
        """
        **`set_auto_mask(self,mask)`**

        turn on or off automatic conversion of variable data to and
        from masked arrays .

        If `mask` is set to `True`, when data is read from a variable
        it is converted to a masked array if any of the values are exactly
        equal to the either the netCDF _FillValue or the value specified by the
        missing_value variable attribute. The fill_value of the masked array
        is set to the missing_value attribute (if it exists), otherwise
        the netCDF _FillValue attribute (which has a default value
        for each data type). If the variable has no missing_value attribute, the
        _FillValue is used instead. If the variable has valid_min/valid_max and
        missing_value attributes, data outside the specified range will be masked.
        When data is written to a variable, the masked
        array is converted back to a regular numpy array by replacing all the
        masked values by the missing_value attribute of the variable (if it
        exists).  If the variable has no missing_value attribute, the _FillValue
        is used instead. 

        The default value of `mask` is `True`
        (automatic conversions are performed).
        """
        self.mask = bool(mask)

    def set_auto_maskandscale(self,maskandscale):
        self.scale = self.mask = bool(maskandscale)

    def _toma(self,data):
        cdef int ierr, no_fill
        # if attribute _Unsigned is True, and variable has signed integer
        # dtype, return view with corresponding unsigned dtype (issues #656,
        # #794)
        is_unsigned = getattr(self, '_Unsigned', False)
        is_unsigned_int = is_unsigned and data.dtype.kind == 'i'
        if self.scale and is_unsigned_int:  # only do this if autoscale option is on.
            dtype_unsigned_int='%su%s' % (data.dtype.byteorder,data.dtype.itemsize)
            data = data.view(dtype_unsigned_int)
        # private function for creating a masked array, masking missing_values
        # and/or _FillValues.
        totalmask = np.zeros(data.shape, np.bool_)
        fill_value = None
        safe_missval = self._check_safecast('missing_value')
        if safe_missval:
            mval = np.array(self.missing_value, self.dtype)
            if self.scale and is_unsigned_int:
                mval = mval.view(dtype_unsigned_int)
            # create mask from missing values.
            mvalmask = np.zeros(data.shape, np.bool_)
            if mval.shape == (): # mval a scalar.
                mval = [mval] # make into iterable.
            for m in mval:
                # is scalar missing value a NaN?
                try:
                    mvalisnan = np.isnan(m)
                except TypeError: # isnan fails on some dtypes (issue 206)
                    mvalisnan = False
                if mvalisnan:
                    mvalmask += np.isnan(data)
                else:
                    mvalmask += data==m
            if mvalmask.any():
                # set fill_value for masked array
                # to missing_value (or 1st element
                # if missing_value is a vector).
                fill_value = mval[0]
                totalmask += mvalmask
        # set mask=True for data == fill value
        safe_fillval = self._check_safecast('_FillValue')
        if safe_fillval:
            fval = np.array(self._FillValue, self.dtype)
            if self.scale and is_unsigned_int:
                fval = fval.view(dtype_unsigned_int)
            # is _FillValue a NaN?
            try:
                fvalisnan = np.isnan(fval)
            except: # isnan fails on some dtypes (issue 202)
                fvalisnan = False
            if fvalisnan:
                mask = np.isnan(data)
            elif (data == fval).any():
                mask = data==fval
            else:
                mask = None
            if mask is not None:
                if fill_value is None:
                    fill_value = fval
                totalmask += mask
        # issue 209: don't return masked array if variable filling
        # is disabled.
        else:
            with nogil:
                ierr = ncmpi_inq_var_fill(self._file_id,self._varid,&no_fill,NULL)
            _check_err(ierr)
            # if no_fill is not 1, and not a byte variable, then use default fill value.
            # from http://www.unidata.ucar.edu/software/netcdf/docs/netcdf-c/Fill-Values.html#Fill-Values
            # "If you need a fill value for a byte variable, it is recommended
            # that you explicitly define an appropriate _FillValue attribute, as
            # generic utilities such as ncdump will not assume a default fill
            # value for byte variables."
            # Explained here too:
            # http://www.unidata.ucar.edu/software/netcdf/docs/known_problems.html#ncdump_ubyte_fill
            # "There should be no default fill values when reading any byte
            # type, signed or unsigned, because the byte ranges are too
            # small to assume one of the values should appear as a missing
            # value unless a _FillValue attribute is set explicitly."
            # (do this only for non-vlens, since vlens don't have a default _FillValue)
            if  (no_fill != 1 or self.dtype.str[1:] not in ['u1','i1']):
                fillval = np.array(default_fillvals[self.dtype.str[1:]],self.dtype)
                has_fillval = data == fillval
                # if data is an array scalar, has_fillval will be a boolean.
                # in that case convert to an array.
                if type(has_fillval) == bool: has_fillval=np.asarray(has_fillval)
                if has_fillval.any():
                    if fill_value is None:
                        fill_value = fillval
                    mask=data==fillval
                    totalmask += mask
        # set mask=True for data outside valid_min,valid_max.
        # (issue #576)
        validmin = None; validmax = None
        # if valid_range exists use that, otherwise
        # look for valid_min, valid_max.  No special
        # treatment of byte data as described at
        # http://www.unidata.ucar.edu/software/netcdf/docs/attribute_conventions.html).
        safe_validrange = self._check_safecast('valid_range')
        safe_validmin = self._check_safecast('valid_min')
        safe_validmax = self._check_safecast('valid_max')
        if safe_validrange and self.valid_range.size == 2:
            validmin = np.array(self.valid_range[0], self.dtype)
            validmax = np.array(self.valid_range[1], self.dtype)
        else:
            if safe_validmin:
                validmin = np.array(self.valid_min, self.dtype)
            if safe_validmax:
                validmax = np.array(self.valid_max, self.dtype)
        if validmin is not None and self.scale and is_unsigned_int:
            validmin = validmin.view(dtype_unsigned_int)
        if validmax is not None and self.scale and is_unsigned_int:
            validmax = validmax.view(dtype_unsigned_int)
        # http://www.unidata.ucar.edu/software/netcdf/docs/attribute_conventions.html).
        # "If the data type is byte and _FillValue
        # is not explicitly defined,
        # then the valid range should include all possible values.
        # Otherwise, the valid range should exclude the _FillValue
        # (whether defined explicitly or by default) as follows.
        # If the _FillValue is positive then it defines a valid maximum,
        #  otherwise it defines a valid minimum."
        byte_type = self.dtype.str[1:] in ['u1','i1']
        if safe_fillval:
            fval = np.array(self._FillValue, self.dtype)
        else:
            fval = np.array(default_fillvals[self.dtype.str[1:]],self.dtype)
            if byte_type: fval = None
        if self.dtype.kind != 'S': # don't set mask for character data
            # issues #761 and #748:  setting valid_min/valid_max to the
            # _FillVaue is too surprising for many users (despite the
            # netcdf docs attribute best practices suggesting clients
            # should do this).
            #if validmin is None and (fval is not None and fval <= 0):
            #    validmin = fval
            #if validmax is None and (fval is not None and fval > 0):
            #    validmax = fval
            if validmin is not None:
                totalmask += data < validmin
            if validmax is not None:
                totalmask += data > validmax
        if fill_value is None and fval is not None:
            fill_value = fval
        # if all else fails, use default _FillValue as fill_value
        # for masked array.
        if fill_value is None:
            fill_value = default_fillvals[self.dtype.str[1:]]
        # create masked array with computed mask
        masked_values = bool(totalmask.any())
        if masked_values:
            data = np.ma.masked_array(data,mask=totalmask,fill_value=fill_value)
        else:
            # issue #785: always return masked array, if no values masked
            data = np.ma.masked_array(data)
        # issue 515 scalar array with mask=True should be converted
        # to np.ma.MaskedConstant to be consistent with slicing
        # behavior of masked arrays.
        if data.shape == () and data.mask.all():
            # return a scalar numpy masked constant not a 0-d masked array,
            # so that data == np.ma.masked.
            data = data[()] # changed from [...] (issue #662)
        elif not self.always_mask and not masked_values:
            # issue #809: return a regular numpy array if requested
            # and there are no missing values
            data = np.array(data, copy=False)

        return data

    def __getitem__(self, elem):
        # This special method is used to index the netCDF variable
        # using the "extended slice syntax". The extended slice syntax
        # is a perfect match for the "start", "count" and "stride"
        # arguments to the ncmpi_get_var() function, and is much more easy
        # to use.
        start, count, stride, put_ind =\
        _StartCountStride(elem,self.shape,dimensions=self.dimensions,file=self._file)
        datashape = _out_array_shape(count)
        data = np.empty(datashape, dtype=self.dtype)

        # Determine which dimensions need to be
        # squeezed (those for which elem is an integer scalar).
        # The convention used is that for those cases,
        # put_ind for this dimension is set to -1 by _StartCountStride.
        squeeze = data.ndim * [slice(None),]
        for i,n in enumerate(put_ind.shape[:-1]):
            if n == 1 and put_ind.size > 0 and put_ind[...,i].ravel()[0] == -1:
                squeeze[i] = 0

        # Reshape the arrays so we can iterate over them.
        start = start.reshape((-1, self.ndim or 1))
        count = count.reshape((-1, self.ndim or 1))
        stride = stride.reshape((-1, self.ndim or 1))
        put_ind = put_ind.reshape((-1, self.ndim or 1))

        # Fill output array with data chunks.
        for (a,b,c,i) in zip(start, count, stride, put_ind):
            datout = self._get(a,b,c)
            if not hasattr(datout,'shape') or data.shape == datout.shape:
                data = datout
            else:
                shape = getattr(data[tuple(i)], 'shape', ())
                if not len(self.dimensions):
                    # special case of scalar VLEN
                    data[0] = datout
                else:
                    data[tuple(i)] = datout.reshape(shape)

        # Remove extra singleton dimensions.
        if hasattr(data,'shape'):
            data = data[tuple(squeeze)]
        if hasattr(data,'ndim') and self.ndim == 0:
            # Make sure a numpy scalar array is returned instead of a 1-d array of
            # length 1.
            if data.ndim != 0: data = np.asarray(data[0])

        # if auto_scale mode set to True, (through
        # a call to set_auto_scale or set_auto_maskandscale),
        # perform automatic unpacking using scale_factor/add_offset.
        # if auto_mask mode is set to True (through a call to
        # set_auto_mask or set_auto_maskandscale), perform
        # automatic conversion to masked array using
        # missing_value/_Fill_Value.
        # applied for primitive and (non-string) vlen,
        # ignored for compound and enum datatypes.
        try: # check to see if scale_factor and add_offset is valid (issue 176).
            if hasattr(self,'scale_factor'): float(self.scale_factor)
            if hasattr(self,'add_offset'): float(self.add_offset)
            valid_scaleoffset = True
        except:
            valid_scaleoffset = False
            if self.scale:
                msg = 'invalid scale_factor or add_offset attribute, no unpacking done...'
                warnings.warn(msg)

        if self.mask:\
            data = self._toma(data)
        else:
            # if attribute _Unsigned is True, and variable has signed integer
            # dtype, return view with corresponding unsigned dtype (issue #656)
            if self.scale:  # only do this if autoscale option is on.
                is_unsigned = getattr(self, '_Unsigned', False)
                if is_unsigned and data.dtype.kind == 'i':
                    data=data.view('%su%s'%(data.dtype.byteorder,data.dtype.itemsize))

        if self.scale and valid_scaleoffset:
            # if variable has scale_factor and add_offset attributes, apply
            # them.
            if hasattr(self, 'scale_factor') and hasattr(self, 'add_offset'):
                if self.add_offset != 0.0 or self.scale_factor != 1.0:
                    data = data*self.scale_factor + self.add_offset
                else:
                    data = data.astype(self.scale_factor.dtype) # issue 913
            # else if variable has only scale_factor attribute, rescale.
            elif hasattr(self, 'scale_factor') and self.scale_factor != 1.0:
                data = data*self.scale_factor
            # else if variable has only add_offset attribute, add offset.
            elif hasattr(self, 'add_offset') and self.add_offset != 0.0:
                data = data + self.add_offset

        # if _Encoding is specified for a character variable, return
        # a numpy array of strings with one less dimension.
        if self.chartostring and getattr(self.dtype,'kind',None) == 'S' and\
           getattr(self.dtype,'itemsize',None) == 1:
            encoding = getattr(self,'_Encoding',None)
            # should this only be done if self.scale = True?
            # should there be some other way to disable this?
            if encoding is not None:
                # only try to return a string array if rightmost dimension of
                # sliced data matches rightmost dimension of char variable
                if len(data.shape) > 0 and data.shape[-1] == self.shape[-1]:
                    # also make sure slice is along last dimension
                    matchdim = True
                    for cnt in count:
                        if cnt[-1] != self.shape[-1]:
                            matchdim = False
                            break
                    if matchdim:
                        data = chartostring(data, encoding=encoding)
        return data

    def _pack(self,data):
        # pack non-masked values using scale_factor and add_offset
        if hasattr(self, 'scale_factor') and hasattr(self, 'add_offset'):
            data = (data - self.add_offset)/self.scale_factor
            if self.dtype.kind in 'iu': data = np.around(data)
        elif hasattr(self, 'scale_factor'):
            data = data/self.scale_factor
            if self.dtype.kind in 'iu': data = np.around(data)
        elif hasattr(self, 'add_offset'):
            data = data - self.add_offset
            if self.dtype.kind in 'iu': data = np.around(data)
        if np.ma.isMA(data):
            # if underlying data in masked regions of masked array
            # corresponds to missing values, don't fill masked array -
            # just use underlying data instead
            if hasattr(self, 'missing_value') and \
               np.all(np.in1d(data.data[data.mask],self.missing_value)):
                data = data.data
            else:
                if hasattr(self, 'missing_value'):
                    # if missing value is a scalar, use it as fill_value.
                    # if missing value is a vector, raise an exception
                    # since we then don't know how to fill in masked values.
                    if np.array(self.missing_value).shape == ():
                        fillval = self.missing_value
                    else:
                        msg="cannot assign fill_value for masked array when missing_value attribute is not a scalar"
                        raise RuntimeError(msg)
                    if np.array(fillval).shape != ():
                        fillval = fillval[0]
                elif hasattr(self, '_FillValue'):
                    fillval = self._FillValue
                else:
                    fillval = default_fillvals[self.dtype.str[1:]]
                # some versions of numpy have trouble handling
                # MaskedConstants when filling - this is is
                # a workaround (issue #850)
                if data.shape == (1,) and data.mask.all():
                    data = np.array([fillval],self.dtype)
                else:
                    data = data.filled(fill_value=fillval)
        if self.dtype != data.dtype:
            data = data.astype(self.dtype) # cast data to var type, if necessary.
        return data

    def __setitem__(self, elem, data):
        # This special method is used to assign to the netCDF variable
        # using "extended slice syntax". The extended slice syntax
        # is a perfect match for the "start", "count" and "stride"
        # arguments to the ncmpi_put_var() function, and is much more easy
        # to use.

        # if _Encoding is specified for a character variable, convert
        # numpy array of strings to a numpy array of characters with one more
        # dimension.
        if self.chartostring and getattr(self.dtype,'kind',None) == 'S' and\
           getattr(self.dtype,'itemsize',None) == 1:
            # NC_CHAR variable
            encoding = getattr(self,'_Encoding',None)
            if encoding is not None:
                # _Encoding attribute is set
                # if data is a string or a bytes object, convert to a numpy string array
                # whose length is equal to the rightmost dimension of the
                # variable.
                if type(data) in [str,bytes]: data = np.asarray(data,dtype='S'+repr(self.shape[-1]))
                if data.dtype.kind in ['S','U'] and data.dtype.itemsize > 1:
                    # if data is a numpy string array, convert it to an array
                    # of characters with one more dimension.
                    data = stringtochar(data, encoding=encoding)

        # A numpy or masked array (or an object supporting the buffer interface) is needed.
        # Convert if necessary.
        if not np.ma.isMA(data) and not (hasattr(data,'data') and isinstance(data.data,memoryview)):
            # if auto scaling is to be done, don't cast to an integer yet.
            if self.scale and self.dtype.kind in 'iu' and \
               hasattr(self, 'scale_factor') or hasattr(self, 'add_offset'):
                data = np.array(data,np.float64)
            else:
                data = np.array(data,self.dtype)

        start, count, stride, put_ind =\
        _StartCountStride(elem,self.shape,self.dimensions,self._file,datashape=data.shape,put=True)
        datashape = _out_array_shape(count)

        # if a numpy scalar, create an array of the right size
        # and fill with scalar values.
        if data.shape == ():
            data = np.tile(data,datashape)
        # reshape data array if needed to conform with start,count,stride.
        if data.ndim != len(datashape) or\
           (data.shape != datashape and data.ndim > 1): # issue #1083
            # create a view so shape in caller is not modified (issue 90)
            try: # if extra singleton dims, just reshape
                data = data.view()
                data.shape = tuple(datashape)
            except ValueError: # otherwise broadcast
                data = np.broadcast_to(data, datashape)

        # Reshape these arrays so we can iterate over them.
        start = start.reshape((-1, self.ndim or 1))
        count = count.reshape((-1, self.ndim or 1))
        stride = stride.reshape((-1, self.ndim or 1))
        put_ind = put_ind.reshape((-1, self.ndim or 1))

        if self.scale:
            # pack non-masked values using scale_factor and add_offset
            data = self._pack(data)

        # Fill output array with data chunks.
        for (a,b,c,i) in zip(start, count, stride, put_ind):
            dataput = data[tuple(i)]
            if dataput.size == 0: continue # nothing to write
            # convert array scalar to regular array with one element.
            if dataput.shape == ():
                dataput=np.array(dataput,dataput.dtype)
            self._put(dataput,a,b,c)

    def _check_safecast(self, attname):
        # check to see that variable attribute exists
        # and can be safely cast to variable data type.
        msg="""WARNING: %s not used since it
                cannot be safely cast to variable data type""" % attname
        if hasattr(self, attname):
            att = np.array(self.getncattr(attname))
        else:
            return False
        try:
            atta = np.array(att, self.dtype)
        except ValueError:
            is_safe = False
            warnings.warn(msg)
            return is_safe
        is_safe = _safecast(att,atta)
        if not is_safe:
            warnings.warn(msg)
        return is_safe

    def _put_var1(self, value, tuple index, collective = True):
        cdef int ierr, ndims
        cdef size_t *indexp
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef ndarray data
        # rank of variable.
        data = np.array(value)
        ndim_index = len(index)
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        indexp = <size_t *>malloc(sizeof(size_t) * ndim_index)
        bufcount = NC_COUNT_IGNORE
        for i, val in enumerate(index):
            indexp[i] = val
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_put_var1_all(self._file_id, self._varid, \
                                    <const MPI_Offset *>indexp, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_var1(self._file_id, self._varid, \
                                    <const MPI_Offset *>indexp, PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)
        free(indexp)

    def _put_var(self, ndarray data, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        #data = data.flatten()
        bufcount = NC_COUNT_IGNORE
        #bufcount = data.size
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        #buftype = MPI_DATATYPE_NULL
        if collective:
            with nogil:
                ierr = ncmpi_put_var_all(self._file_id, self._varid, \
                                     PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_var(self._file_id, self._varid, \
                                     PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)

    def _put_vara(self, start, count, ndarray data, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        #data = data.flatten()
        bufcount = NC_COUNT_IGNORE
        #bufcount = data.size
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_put_vara_all(self._file_id, self._varid, <const MPI_Offset *>startp, <const MPI_Offset *>countp,\
                                     PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_vara(self._file_id, self._varid, <const MPI_Offset *>startp, <const MPI_Offset *>countp,\
                                     PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)

    def _put_varn(self, start, count, num, ndarray data, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t **startp
        cdef size_t **countp
        cdef int num_req
        num_req = num
        ndims = len(self.dimensions)
        max_num_req = len(start)

        startp = <size_t**> malloc(max_num_req * sizeof(size_t*));
        for i in range(max_num_req):
            startp[i] = <size_t*> malloc(ndims * sizeof(size_t));
            for j in range(ndims):
                startp[i][j] = start[i, j]

        countp = <size_t**> malloc(max_num_req * sizeof(size_t*));
        for i in range(max_num_req):
            countp[i] = <size_t*> malloc(ndims * sizeof(size_t));
            for j in range(ndims):
                countp[i][j] = count[i, j]

        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        #data = data.flatten()
        bufcount = NC_COUNT_IGNORE
        #bufcount = data.size
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_put_varn_all(self._file_id, self._varid, num_req, <const MPI_Offset **>startp, <const MPI_Offset **>countp,\
                                     PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_varn(self._file_id, self._varid, num_req, <const MPI_Offset **>startp, <const MPI_Offset **>countp,\
                                     PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)

    def _put_vars(self, start, count, stride, ndarray data, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
            stridep[n] = stride[n]
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        #data = data.flatten()
        bufcount = NC_COUNT_IGNORE
        #bufcount = data.size
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_put_vars_all(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_vars(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)


    def _put_varm(self, ndarray data, start, count, stride, imap, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        cdef size_t *imapp
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        imapp = <size_t *>malloc(sizeof(size_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
            stridep[n] = stride[n]
            imapp[n] = imap[n]
        shapeout = ()
        for lendim in count:
            shapeout = shapeout + (lendim,)
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        bufcount = NC_COUNT_IGNORE
        if data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_put_varm_all(self._file_id, self._varid, <const MPI_Offset *>startp, \
                                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, \
                                        <const MPI_Offset *>imapp, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_put_varm(self._file_id, self._varid, <const MPI_Offset *>startp, \
                                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, \
                                        <const MPI_Offset *>imapp, PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)
        return data

    


    def put_var(self, data, index=None, start=None, count=None, stride=None, num=None, imap=None):
        if data is not None and all(arg is None for arg in [index, start, count, stride, num, imap]):
            self._put_var(data, collective = False)
        elif all(arg is not None for arg in [data, index]) and all(arg is None for arg in [start, count, stride, num, imap]):
            self._put_var1(data, index, collective = False)
        elif all(arg is not None for arg in [data, start, count]) and all(arg is None for arg in [index, stride, num, imap]):
            self._put_vara(start, count, data, collective = False)
        elif all(arg is not None for arg in [data, start, count, stride]) and all(arg is None for arg in [index, num, imap]):
            self._put_vars(start, count, stride, data, collective = False)
        elif all(arg is not None for arg in [data, start, count, num]) and all(arg is None for arg in [index, stride, imap]):
            self._put_varn(start, count, num, data, collective = False)
        elif all(arg is not None for arg in [data, start, count, stride, imap, data]) and all(arg is None for arg in [index, num]):
            self._put_varm(data, start, count, stride, imap, collective = False)
        else:
            raise ValueError("Invalid input arguments for put_var")

    def put_var_all(self, data, index=None, start=None, count=None, stride=None, num=None, imap=None):
        if data is not None and all(arg is None for arg in [index, start, count, stride, num, imap]):
            self._put_var(data, collective = True)
        elif all(arg is not None for arg in [data, index]) and all(arg is None for arg in [start, count, stride, num, imap]):
            self._put_var1(data, index, collective = True)
        elif all(arg is not None for arg in [data, start, count]) and all(arg is None for arg in [index, stride, num, imap]):
            self._put_vara(start, count, data, collective = True)
        elif all(arg is not None for arg in [data, start, count, stride]) and all(arg is None for arg in [index, num, imap]):
            self._put_vars(start, count, stride, data, collective = True)
        elif all(arg is not None for arg in [data, start, count, num]) and all(arg is None for arg in [index, stride, imap]):
            self._put_varn(start, count, num, data, collective = True)
        elif all(arg is not None for arg in [data, start, count, stride, imap, data]) and all(arg is None for arg in [index, num]):
            self._put_varm(data, start, count, stride, imap, collective = True)
        else:
            raise ValueError("Invalid input arguments for put_var_all")

    def _put(self, ndarray data, start, count, stride):
        """Private method to put data into a netCDF variable"""
        cdef int ierr, ndims
        cdef npy_intp totelem
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        cdef char **strdata
        cdef void* elptr
        cdef char* databuff
        cdef ndarray dataarr
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        # rank of variable.
        ndims = len(self.dimensions)
        # make sure data is contiguous.
        # if not, make a local copy.
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        # fill up startp,countp,stridep.
        totelem = 1
        negstride = 0
        sl = []
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        for n from 0 <= n < ndims:
            count[n] = abs(count[n]) # make -1 into +1
            countp[n] = count[n]
            # for neg strides, reverse order (then flip that axis after data read in)
            if stride[n] < 0:
                negstride = 1
                stridep[n] = -stride[n]
                startp[n] = start[n]+stride[n]*(count[n]-1)
                stride[n] = -stride[n]
                sl.append(slice(None, None, -1)) # this slice will reverse the data
            else:
                startp[n] = start[n]
                stridep[n] = stride[n]
                sl.append(slice(None, None, 1))
            totelem = totelem*countp[n]
        # check to see that size of data array is what is expected
        # for slice given.
        dataelem = PyArray_SIZE(data)
        if totelem != dataelem:
            raise IndexError('size of data array does not conform to slice')
        if negstride:
            # reverse data along axes with negative strides.
            data = data[tuple(sl)].copy() # make sure a copy is made.
        if self.dtype != data.dtype:
            data = data.astype(self.dtype) # cast data, if necessary.
        # byte-swap data in numpy array so that is has native
        # endian byte order (this is what netcdf-c expects -
        # issue #554, pull request #555)
        if not data.dtype.isnative:
            data = data.byteswap()
        # strides all 1 or scalar variable, use put_vara (faster)
        #bufcount = data.size
        bufcount = NC_COUNT_IGNORE
        if self._file.data_model != "64BIT_DATA":
            #check if dtype meets CDF-5 variable standards
            if data.dtype.str[1:] not in _supportedtypescdf2:
                raise TypeError, 'illegal data type, must be one of %s, got %s' % \
                (_supportedtypescdf2, data.dtype.str[1:])
        #check if dtype meets CDF-5 variable standards
        elif data.dtype.str[1:] not in _supportedtypes:
            raise TypeError, 'illegal data type, must be one of %s, got %s' % \
            (_supportedtypes, data.dtype.str[1:])
        buftype = _nptompitype[data.dtype.str[1:]]
        if self._file.indep_mode:
            if sum(stride) == ndims or ndims == 0:
                with nogil:
                    ierr = ncmpi_put_vara(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        PyArray_DATA(data), bufcount, buftype)
            else:
                with nogil:
                    ierr = ncmpi_put_vars(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
        else:
            if sum(stride) == ndims or ndims == 0:
                with nogil:
                    ierr = ncmpi_put_vara_all(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        PyArray_DATA(data), bufcount, buftype)
            else:
                with nogil:
                    ierr = ncmpi_put_vars_all(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)

        _check_err(ierr)
        free(startp)
        free(countp)
        free(stridep)

    def _get_var1(self, index, collective = True):
        cdef int ierr, ndims
        cdef size_t *indexp
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef ndarray data
        data = np.empty((), self.dtype)
        ndim_index = len(index)
        indexp = <size_t *>malloc(sizeof(size_t) * ndim_index)
        bufcount = NC_COUNT_IGNORE
        for i, val in enumerate(index):
            indexp[i] = val
        buftype = MPI_DATATYPE_NULL
        if collective:
            with nogil:
                ierr = ncmpi_get_var1_all(self._file_id, self._varid, \
                                    <const MPI_Offset *>indexp, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_get_var1(self._file_id, self._varid, \
                                    <const MPI_Offset *>indexp, PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)
        free(indexp)
        return data

    def _get_var(self, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef ndarray data
        shapeout = ()
        for dimname in self.dimensions:
            dim = self._file.dimensions[dimname]
            shapeout += (len(dim),)
        data = np.empty(shapeout, self.dtype)
        bufcount = NC_COUNT_IGNORE
        buftype = MPI_DATATYPE_NULL

        if collective:
            with nogil:
                ierr = ncmpi_get_var_all(self._file_id, self._varid, \
                                    PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_get_var(self._file_id, self._varid, \
                                    PyArray_DATA(data), bufcount, buftype)

        _check_err(ierr)
        return data

    def _get_vara(self, start, count, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        cdef ndarray data
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
        shapeout = ()
        for lendim in count:
            shapeout = shapeout + (lendim,)
        data = np.empty(shapeout, self.dtype)
        bufcount = NC_COUNT_IGNORE
        buftype = MPI_DATATYPE_NULL
        if collective:
            with nogil:
                ierr = ncmpi_get_vara_all(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_get_vara(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        PyArray_DATA(data), bufcount, buftype)

        _check_err(ierr)
        return data

    def _get_varn(self, start, count, num, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t **startp
        cdef size_t **countp
        cdef ndarray data
        cdef int num_req
        num_req = num
        ndims = len(self.dimensions)
        max_num_req = len(start)
        startp = <size_t**> malloc(max_num_req * sizeof(size_t*));
        for i in range(max_num_req):
            startp[i] = <size_t*> malloc(ndims * sizeof(size_t));
            for j in range(ndims):
                startp[i][j] = start[i][j]

        countp = <size_t**> malloc(max_num_req * sizeof(size_t*));
        for i in range(max_num_req):
            countp[i] = <size_t*> malloc(ndims * sizeof(size_t));
            for j in range(ndims):
                countp[i][j] = count[i][j]

        buf_len = 0
        for i in range(num_req):
            r_req_len = 1
            for j in range(ndims):
                r_req_len*= count[i][j]
            buf_len += r_req_len
        data = np.empty(buf_len, self.dtype)
        bufcount = NC_COUNT_IGNORE
        #buftype = MPI_DATATYPE_NULL
        buftype = _nptompitype[self.dtype.str[1:]]
        if collective:
            with nogil:
                ierr = ncmpi_get_varn_all(self._file_id, self._varid, num_req,\
                                        <const MPI_Offset **>startp, <const MPI_Offset **>countp, \
                                        PyArray_DATA(data), bufcount, buftype)

        else:
            with nogil:
                ierr = ncmpi_get_varn(self._file_id, self._varid, num_req,\
                                        <const MPI_Offset **>startp, <const MPI_Offset **>countp, \
                                        PyArray_DATA(data), bufcount, buftype)

        _check_err(ierr)
        return data

    def _get_vars(self, start, count, stride, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        cdef ndarray data
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
            stridep[n] = stride[n]
        shapeout = ()
        for lendim in count:
            shapeout = shapeout + (lendim,)
        data = np.empty(shapeout, self.dtype)
        bufcount = NC_COUNT_IGNORE
        buftype = MPI_DATATYPE_NULL
        if collective:
            with nogil:
                ierr = ncmpi_get_vars_all(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_get_vars(self._file_id, self._varid, \
                                        <const MPI_Offset *>startp, <const MPI_Offset *>countp, \
                                        <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)

        _check_err(ierr)
        return data

    def _get_varm(self, ndarray data, start, count, stride, imap, collective = True):
        cdef int ierr, ndims
        cdef MPI_Offset bufcount
        cdef MPI_Datatype buftype
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        cdef size_t *imapp
        ndims = len(self.dimensions)
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        imapp = <size_t *>malloc(sizeof(size_t) * ndims)
        for n from 0 <= n < ndims:
            countp[n] = count[n]
            startp[n] = start[n]
            stridep[n] = stride[n]
            imapp[n] = imap[n]
        shapeout = ()
        for lendim in count:
            shapeout = shapeout + (lendim,)
        if not PyArray_ISCONTIGUOUS(data):
            data = data.copy()
        bufcount = NC_COUNT_IGNORE
        buftype = MPI_DATATYPE_NULL
        if collective:
            with nogil:
                ierr = ncmpi_get_varm_all(self._file_id, self._varid, <const MPI_Offset *>startp, \
                                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, \
                                        <const MPI_Offset *>imapp, PyArray_DATA(data), bufcount, buftype)
        else:
            with nogil:
                ierr = ncmpi_get_varm(self._file_id, self._varid, <const MPI_Offset *>startp, \
                                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, \
                                        <const MPI_Offset *>imapp, PyArray_DATA(data), bufcount, buftype)
        _check_err(ierr)
        return data

    def get_var(self, data=None, index=None, start=None, count=None, stride=None, num=None, imap=None):
        if all(arg is None for arg in [data, index, start, count, stride, num, imap]):
            return self._get_var(collective = False)
        elif index is not None and all(arg is None for arg in [data, start, count, stride, num, imap]):
            return self._get_var1(index, collective = False)
        elif all(arg is not None for arg in [start, count]) and all(arg is None for arg in [data, index, stride, num, imap]):
            return self._get_vara(start, count, collective = False)
        elif all(arg is not None for arg in [start, count, stride]) and all(arg is None for arg in [data, index, num, imap]):
            return self._get_vars(start, count, stride, collective = False)
        elif all(arg is not None for arg in [start, count, num]) and all(arg is None for arg in [data, index, stride, imap]):
            return self._get_varn(start, count, num, collective = False)
        elif all(arg is not None for arg in [start, count, stride, imap, data]) and all(arg is None for arg in [index, num]):
            return self._get_varm(data, start, count, stride, imap, collective = False)
        else:
            raise ValueError("Invalid input arguments for get_var")

    def get_var_all(self, data=None, index=None, start=None, count=None, stride=None, num=None, imap=None):
        if all(arg is None for arg in [data, index, start, count, stride, num, imap]):
            return self._get_var(collective = True)
        elif index is not None and all(arg is None for arg in [data, start, count, stride, num, imap]):
            return self._get_var1(index, collective = True)
        elif all(arg is not None for arg in [start, count]) and all(arg is None for arg in [data, index, stride, num, imap]):
            return self._get_vara(start, count, collective = True)
        elif all(arg is not None for arg in [start, count, stride]) and all(arg is None for arg in [data, index, num, imap]):
            return self._get_vars(start, count, stride, collective = True)
        elif all(arg is not None for arg in [start, count, num]) and all(arg is None for arg in [data, index, stride, imap]):
            return self._get_varn(start, count, num, collective = True)
        elif all(arg is not None for arg in [start, count, stride, imap, data]) and all(arg is None for arg in [index, num]):
            return self._get_varm(data, start, count, stride, imap, collective = True)
        else:
            raise ValueError("Invalid input arguments for get_var")

    def _get(self,start,count,stride):
        """Private method to retrieve data from a netCDF variable"""
        cdef int ierr, ndims, totelem
        cdef size_t *startp
        cdef size_t *countp
        cdef ptrdiff_t *stridep
        cdef ndarray data, dataarr
        cdef void *elptr
        cdef char **strdata
        cdef int file_id = self._file._ncid
        # if one of the counts is negative, then it is an index
        # and not a slice so the resulting array
        # should be 'squeezed' to remove the singleton dimension.
        shapeout = ()
        squeeze_out = False
        for lendim in count:
            if lendim == -1:
                shapeout = shapeout + (1,)
                squeeze_out = True
            else:
                shapeout = shapeout + (lendim,)
        # rank of variable.
        ndims = len(self.dimensions)
        # fill up startp,countp,stridep.
        negstride = 0
        sl = []
        startp = <size_t *>malloc(sizeof(size_t) * ndims)
        countp = <size_t *>malloc(sizeof(size_t) * ndims)
        stridep = <ptrdiff_t *>malloc(sizeof(ptrdiff_t) * ndims)
        for n from 0 <= n < ndims:
            count[n] = abs(count[n]) # make -1 into +1
            countp[n] = count[n]
            # for neg strides, reverse order (then flip that axis after data read in)
            if stride[n] < 0:
                negstride = 1
                stridep[n] = -stride[n]
                startp[n] = start[n]+stride[n]*(count[n]-1)
                stride[n] = -stride[n]
                sl.append(slice(None, None, -1)) # this slice will reverse the data
            else:
                startp[n] = start[n]
                stridep[n] = stride[n]
                sl.append(slice(None,None, 1))

        data = np.empty(shapeout, self.dtype)
        # strides all 1 or scalar variable, use get_vara (faster)
        # if count contains a zero element, no data is being read
        bufcount = NC_COUNT_IGNORE
        buftype = MPI_DATATYPE_NULL

        if 0 not in count:
            if self._file.indep_mode:
                if sum(stride) == ndims or ndims == 0:
                    with nogil:
                        ierr = ncmpi_get_vara(self._file_id, self._varid,<const MPI_Offset *>startp, \
                        <const MPI_Offset *>countp, PyArray_DATA(data), bufcount, buftype)
                else:
                    with nogil:
                        ierr = ncmpi_get_vars(self._file_id, self._varid, <const MPI_Offset *>startp, \
                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
            else:
                if sum(stride) == ndims or ndims == 0:
                    with nogil:
                        ierr = ncmpi_get_vara_all(self._file_id, self._varid, <const MPI_Offset *>startp, \
                        <const MPI_Offset *>countp, PyArray_DATA(data), bufcount, buftype)
                else:
                    with nogil:
                        ierr = ncmpi_get_vars_all(self._file_id, self._varid, <const MPI_Offset *>startp, \
                        <const MPI_Offset *>countp, <const MPI_Offset *>stridep, PyArray_DATA(data), bufcount, buftype)
        else:
            ierr = 0
        if ierr == NC_EINVALCOORDS:
            raise IndexError('index exceeds dimension bounds')
        elif ierr != NC_NOERR:
            _check_err(ierr)

        free(startp)
        free(countp)
        free(stridep)
        if negstride:
            # reverse data along axes with negative strides.
            data = data[tuple(sl)].copy() # make a copy so data is contiguous.
        # netcdf-c always returns data in native byte order,
        # regardless of variable endian-ness. Here we swap the
        # bytes if the variable dtype is not native endian, so the
        # dtype of the returned numpy array matches the variable dtype.
        # (pull request #555, issue #554).
        if not data.dtype.isnative:
            data.byteswap(True) # in-place byteswap
        if not self.dimensions:
            return data[0] # a scalar
        elif squeeze_out:
            return np.squeeze(data)
        else:
            return data