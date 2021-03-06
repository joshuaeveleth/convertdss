#' Initilizes a ncdf file to recieve dss data
#' 
#' Uses an open dss file. A time dimension is defined with a corresponding 
#' dimensional variable (a variable with the same name as the dimension).
#' 
#' It is important that all the times be defined before any data gets written,
#' netcdf works like a large array, and so inserting new times only works at the 
#' end of a series. It is not possible to insert values at times that don't already 
#' exist if those times are at the beginning or middle of a time dimension. This 
#' makes it vary tricky to convert an arbirtrary dss file which may have irregular 
#' timeseries data. For this reason, initialization of time stamps is left to the user.
#' 
#' @param dss a dss file object from \code{\link[dssrip]{opendss}}
#' @param datetimes a vector of datetimes (such as from \code{\link[libridate]{ymd_hms}})
#'                  corresponding to the exact times to set up in the nc file
#'                  
#' 
#' @return An ncdf4 file handle
#' @author Cameron Bracken
#' @export 
dss_to_ncdf_init <- function(dss,datetimes,nc_file='convertdss.nc',overwrite=FALSE){

    if(file.exists(nc_file))
        if(overwrite)
            unlink(nc_file)
        else
            stop(sprintf('File %s already exists, set overwrite=TRUE to clobber it.',nc_file))
    
    #--------------------------------------------------------------
    # Make dimensions. Setting "dimnchar" to have a length of 12
    # means that the maximum timestamp 
    # length can be 12.  Longer names will be truncated to this.
    # We don't need dimvars for this example.
    #--------------------------------------------------------------
    dim_nchar = ncdim_def("max_string_length", "", 1:nchar("0000-00-00 00-00-00 UTC"), create_dimvar=FALSE)
    dim_time = ncdim_def("time_index",  units="", 1:length(datetimes), create_dimvar=FALSE)

    #------------------------------------------------------------------------
    # NOTE in the following call that units is set to the empty string (""),
    # which suppresses creation of a units attribute, and the missing value
    # is entirely omitted, which suppresses creation of the missing value att
    #------------------------------------------------------------------------
    var_time = ncvar_def("time_stamp", units="", list(dim_nchar, dim_time), prec='char')

    # we definitely want netcdf version 4 here, version 3 has a default limit
    # of ~8000 variables , which cant be changed without recompiling
    nc = nc_create(nc_file, list(var_time), force_v4=TRUE)
    
    # write the actual values
    ncvar_put(nc, var_time, format(datetimes, '%Y-%m-%d %H:%M:%S UTC'))
    
    ##  Put some global attributes
    ncatt_put(nc, 0, "title", sprintf("Data from %s", basename(dss$getFilename())))
    ncatt_put(nc, 0, "history", paste("Created: ", Sys.time()))

    # ncdf4 writes adds some extra information when its closed and opened
    # otherwise, we get an error when reading the time dimension
    nc_close(nc)

    invisible(NULL)
}
 

#' Writes a dss variable to an existing netcdf file
#' 
#' Uses the output of read_dss_variable, creating a new variable in an _existing_
#' netcdf file
#' 
#' @param v a variable object returned by \code{\link{read_dss_variable}}
#' @param nc A \code{\link[ncdf4]{ncdf4}} file handle set up by \code{\link{dss_to_ncdf_init}}
#' @param nc_datetimes the datetimes from the time variable in the netcdf file
#'                     this is for efficiency so the times do not have to be 
#'                     read and converted for each new variable written.
#' 
#' @return TRUE if the write was successful, false otherwise
#' @author Cameron Bracken
#' @export 
dss_var_to_ncdf <- function(v, nc_file, nc_datetimes=NULL){
    
    nc = nc_open(nc_file,write=TRUE)

    # if the user does not supply nc datetimes of the variable, 
    # read them out of the nc file
    if(is.null(nc_datetimes))
        nc_datetimes = ymd_hms(ncvar_get(nc, 'time_stamp'))

    dim_time = ncdim_def("time_index",  units="", 1:length(nc_datetimes), create_dimvar=FALSE)

    var_name = v$variable
    md = lapply(v$metadata,as.character)

    dss_datetimes = v$data$datetime

    # if either data is longer, use the shorter length 
    ldss = length(dss_datetimes)
    lnc = length(nc_datetimes)
    ml = min(ldss,lnc)

    # check if dates match up, from the first date
    all_match = all(dss_datetimes[1:ml] == nc_datetimes[1:ml])

    # check also if the dss data starts later then the netcdf first time,
    # no support for any other cases
    first_dates_match = (dss_datetimes[1] == nc_datetimes[1])
    init_offset = (dss_datetimes[1] %in% nc_datetimes & !first_dates_match)

    written = FALSE
    if(all_match){

        #define and write the variable
        var_nc = ncvar_def(var_name, units="", dim=dim_time, missval=NA)
        nc_new = ncvar_add(nc, var_nc)
        ncvar_put(nc_new, var_nc, v$data$value)

        written = TRUE

    }else if(init_offset){

        # the value starts at another index but we need to 
        # check datetimes all match up with the existing nc datetimes
        # TODO: possibly grow the time dimension
        init_index = which(dss_datetimes[1] == nc_datetimes)

        runs_over = (ldss > length(nc_datetimes[init_index:lnc]))

        if(runs_over){
            warning('DSS variable and NetCDF times do not match, skipping')
        }else{
            all_match2 = all(dss_datetimes == nc_datetimes[init_index:(init_index + ldss - 1)])

            var_nc = ncvar_def(var_name, units="", dim=dim_time, missval=NA)
            nc_new = ncvar_add(nc, var_nc)
            ncvar_put(nc_new, var_nc, v$data$value, start=init_index, count=length(v$data$value))

            written = TRUE
        }
    }

    if(written){
        # add the metadata
        for(m in names(md))
            ncatt_put(nc_new, var_name, m, as.character(md[[m]]))
        nc_close(nc_new)
    }
    #nc_close(nc)

    return(written)

}

#' Convert dss to netcdf
#' 
#' This function does the bulk of the work to convert dss data to netcdf,
#' but not all of it. In particular, you will need to call \code{\link{dss_to_ncdf_init}}
#' first to set up the netcdf file. The way dss and netcdf handle time data
#' is slightly different and so some data will not convert nicely. See the 
#' description of \code{\link{dss_to_ncdf_init}} for more information
#'
#' @param dss a dss file handle, from opendss
#' @param nc a nc file handle, from dss_to_ncdf_init
#' 
#' @return Outputs a NetCDF file
#' @note NOTE
#' @author Cameron Bracken
#' @seealso \code{\link[dssrip]{opendss}}, \code{\link{dss_to_ncdf_init}}
#' @export 
dss_to_netcdf <- function(dss, nc_file, parts=NULL, variable_parts=LETTERS[1:4]){

    nc = nc_open(nc_file)
    nc_datetimes = ymd_hms(ncvar_get(nc, 'time_stamp'))
    nc_close(nc)

    if(is.null(parts))
        parts = separate_path_parts(getAllPaths(dss),variable_parts)
    dss_variables = unique(parts$id_var)

    for(var in dss_variables){
        message(var)

        dss_var = try({
            read_dss_variable(var, dss, parts, variable_parts)
        },silent = TRUE)

        if(!('try-error' %in% class(dss_var)))
            dss_var_to_ncdf(dss_var, nc_file, nc_datetimes)
    }
}

print.NetCDF <- function(x)print.nc(x)