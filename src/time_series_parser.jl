"""Wraps the data read from the text files with time series"""
struct RawTimeSeries
    initial_time::Dates.DateTime
    data::Dict
    length::Int
end

"""Describes how to construct time_series from raw time series data files."""
mutable struct TimeSeriesFileMetadata
    "User description of simulation"
    simulation::String
    "String version of abstract type for the component associated with the time series."
    category::String
    "Calling module should determine the actual type."
    "Name of time_series component"
    component_name::String
    "User-defined name"
    name::String
    "Controls normalization of time series.
     Use 1.0 for pre-normalized data.
     Use 'Max' to divide the time series by the max value in the column.
     Use any float for a custom scaling factor."
    normalization_factor::Union{String, Float64}
    "Path to the time series data file"
    data_file::String
    "Resolution of the data being parsed in seconds"
    resolution::Dates.Period
    percentiles::Vector{Float64}
    time_series_type::DataType
    "Calling module must set."
    component::Union{Nothing, InfrastructureSystemsComponent}
    "Applicable when data are scaling factors. Accessor function on component to apply to
    values."
    scaling_factor_multiplier::Union{Nothing, String}
    scaling_factor_multiplier_module::Union{Nothing, String}
end

function TimeSeriesFileMetadata(;
    simulation,
    category,
    component_name,
    name,
    normalization_factor,
    data_file,
    resolution,
    percentiles,
    time_series_type_module,
    time_series_type,
    scaling_factor_multiplier = nothing,
    scaling_factor_multiplier_module = nothing,
)
    return TimeSeriesFileMetadata(
        simulation,
        category,
        component_name,
        name,
        normalization_factor,
        data_file,
        resolution,
        percentiles,
        get_type_from_strings(time_series_type_module, time_series_type),
        nothing,
        scaling_factor_multiplier,
        scaling_factor_multiplier_module,
    )
end

"""Reads time_series metadata and fixes relative paths to the data files."""
function read_time_series_file_metadata(file_path::AbstractString)
    if endswith(file_path, ".json")
        metadata = open(file_path) do io
            metadata = Vector{TimeSeriesFileMetadata}()
            data = JSON3.read(io, Array)
            for item in data
                parsed_resolution = Dates.Millisecond(Dates.Second(item["resolution"]))
                normalization_factor = item["normalization_factor"]
                if !isa(normalization_factor, AbstractString)
                    normalization_factor = Float64(normalization_factor)
                end
                scaling_factor_multiplier =
                    get(item, "scaling_factor_multiplier", nothing)
                scaling_factor_multiplier_module =
                    get(item, "scaling_factor_multiplier_module", nothing)
                push!(
                    metadata,
                    TimeSeriesFileMetadata(;
                        simulation = item["simulation"],
                        category = item["category"],
                        component_name = item["component_name"],
                        name = item["name"],
                        normalization_factor = normalization_factor,
                        data_file = item["data_file"],
                        resolution = parsed_resolution,
                        # Use default values until CDM data is updated.
                        percentiles = get(item, "percentiles", []),
                        time_series_type_module = get(
                            item,
                            "module",
                            "InfrastructureSystems",
                        ),
                        time_series_type = get(item, "type", "SingleTimeSeries"),
                        scaling_factor_multiplier = scaling_factor_multiplier,
                        scaling_factor_multiplier_module = scaling_factor_multiplier_module,
                    ),
                )
            end
            return metadata
        end
    elseif endswith(file_path, ".csv")
        csv = DataFrames.DataFrame(CSV.File(file_path))
        metadata = Vector{TimeSeriesFileMetadata}()
        for row in eachrow(csv)
            category = _get_category(row.category)
            scaling_factor_multiplier = get(row, :scaling_factor_multiplier, nothing)
            scaling_factor_multiplier_module =
                get(row, :scaling_factor_multiplier_module, nothing)
            push!(
                metadata,
                TimeSeriesFileMetadata(;
                    simulation = row.simulation,
                    category = row.category,
                    component_name = row.component_name,
                    name = row.name,
                    resolution = Dates.Millisecond(Dates.Second(row.resolution)),
                    normalization_factor = row.normalization_factor,
                    data_file = row.data_file,
                    percentiles = [],
                    time_series_type_module = get(row, :module, "InfrastructureSystems"),
                    time_series_type = get(row, :type, "SingleTimeSeries"),
                    scaling_factor_multiplier = scaling_factor_multiplier,
                    scaling_factor_multiplier_module = scaling_factor_multiplier_module,
                ),
            )
        end

    else
        error("file not supported")
    end

    directory = dirname(file_path)
    for ts_metadata in metadata
        ts_metadata.data_file = abspath(joinpath(directory, ts_metadata.data_file))
    end

    return metadata
end

@scoped_enum NormalizationType begin
    MAX
end

const NormalizationFactor = Union{Float64, NormalizationTypes.NormalizationType}

function handle_normalization_factor(
    data::AbstractDict,
    normalization_factor::NormalizationFactor,
)
    for (k, v) in data
        data[k] = handle_normalization_factor(v, normalization_factor)
    end
    return data
end

get_max_value(ta::TimeSeries.TimeArray) = maximum(TimeSeries.values(ta))
get_max_value(ta::Vector) = maximum(ta)

function handle_normalization_factor(
    ta::Union{TimeSeries.AbstractTimeSeries, AbstractArray},
    normalization_factor::NormalizationFactor,
)
    if normalization_factor isa NormalizationTypes.NormalizationType
        if normalization_factor == NormalizationTypes.MAX
            max_value = get_max_value(ta)
            ta = ta ./ max_value
            @debug "Normalize by max value" max_value
        else
            error("support for normalization_factor=$normalization_factor not implemented")
        end
    else
        if normalization_factor != 1.0
            ta = ta ./ normalization_factor
            @debug "Normalize by custom scaling factor" normalization_factor
        else
            @debug "time_series is already normalized"
        end
    end

    return ta
end

struct TimeSeriesParsedInfo
    simulation::String
    component::InfrastructureSystemsComponent
    name::String  # Component field on which time series data is based.
    normalization_factor::NormalizationFactor
    data::RawTimeSeries
    percentiles::Vector{Float64}
    file_path::String
    resolution::Dates.Period
    scaling_factor_multiplier::Union{Nothing, Function}

    function TimeSeriesParsedInfo(
        simulation,
        component,
        name,
        normalization_factor,
        data,
        percentiles,
        file_path,
        resolution,
        scaling_factor_multiplier = nothing,
    )
        new(
            simulation,
            component,
            name,
            normalization_factor,
            data,
            percentiles,
            abspath(file_path),
            resolution,
            scaling_factor_multiplier,
        )
    end
end

function TimeSeriesParsedInfo(metadata::TimeSeriesFileMetadata, raw_data::RawTimeSeries)
    if (
        metadata.scaling_factor_multiplier === nothing &&
        metadata.scaling_factor_multiplier_module !== nothing
    ) || (
        metadata.scaling_factor_multiplier !== nothing &&
        metadata.scaling_factor_multiplier_module === nothing
    )
        throw(DataFormatError("scaling_factor_multiplier and scaling_factor_multiplier_module must both be set or not set"))
    end

    if metadata.scaling_factor_multiplier === nothing
        multiplier_func = nothing
    else
        multiplier_func = get_type_from_strings(
            metadata.scaling_factor_multiplier_module,
            metadata.scaling_factor_multiplier,
        )
    end

    if metadata.normalization_factor isa String
        if lowercase(metadata.normalization_factor) == "max"
            normalization_factor = NormalizationTypes.MAX
        else
            factor = metadata.normalization_factor
            throw(DataFormatError("unsupported normalization_factor {factor}"))
        end
    elseif metadata.normalization_factor == 0.0
        throw(DataFormatError("unsupported normalization_factor value of 0.0"))
    else
        normalization_factor = metadata.normalization_factor
    end

    return TimeSeriesParsedInfo(
        metadata.simulation,
        metadata.component,
        metadata.name,
        normalization_factor,
        raw_data,
        metadata.percentiles,
        metadata.data_file,
        metadata.resolution,
        multiplier_func,
    )
end

function make_time_array(info::TimeSeriesParsedInfo)
    return make_time_array(info.data, get_name(info.component), info.resolution)
end

function make_time_array(raw::RawTimeSeries, component_name, resolution)
    series_length = raw.length
    ini_time = raw.initial_time
    timestamps = range(ini_time; length = series_length, step = resolution)
    return TimeSeries.TimeArray(timestamps, raw.data[component_name])
end

struct TimeSeriesParsingCache
    time_series_infos::Vector{TimeSeriesParsedInfo}
    data_files::Dict{String, RawTimeSeries}
end

function TimeSeriesParsingCache()
    return TimeSeriesParsingCache(Vector{TimeSeriesParsedInfo}(), Dict{String, Any}())
end

function _add_time_series_info!(
    cache::TimeSeriesParsingCache,
    metadata::TimeSeriesFileMetadata,
)
    if !haskey(cache.data_files, metadata.data_file)
        cache.data_files[metadata.data_file] = read_time_series(metadata)
        @debug "Added time series file" metadata.data_file
    end
    return cache.data_files[metadata.data_file]
end
