library(openrouteservice)  
library(geosphere)         
library(dplyr)            
library(tidyr)             
library(purrr)             
library(progress)          
library(readr)             

# Set OpenRouteService API key (register at https://account.heigit.org/)
# Since personal API keys have call limits, you may need to rotate keys for large batches.
ors_api_key(Sys.getenv("ORS_API_KEY"))

# Read gas station data and rename columns
stations <- read.csv("unique_stations.csv") %>%
  rename(
    station_id = station_uuid,
    lon        = longitude,
    lat        = latitude
  )

# Function to read points of interest (POI)
read_poi <- function(path, poi_id_col = "id") {
  read_csv(path) %>%
    transmute(
      poi_id = !!sym(poi_id_col),
      lon = longitude,
      lat = latitude
    )
}

# Read POI data (e.g. near highways)
# Here we use highway junctions as an example, 
# but you can replace this with coordinates for airports, city centers, train stations, etc.
poi <- read_poi("highway_coords.csv")  # also run for airports, train stations, city centers

# Calculate straight-line (Haversine) distances between gas stations and POIs (in meters)
nearest_n <- 5  # Number of nearest POIs to consider

dist_mat <- geosphere::distm(
  stations %>% select(lon, lat),
  poi       %>% select(lon, lat) %>% as.matrix(),
  fun = geosphere::distHaversine
)

# Get indices of nearest 5 POIs for each station
nearest_poi_idx  <- t(apply(dist_mat, 1, function(d) order(d)[1:nearest_n]))

# Get distances of these nearest 5 POIs
nearest_poi_dist <- t(apply(dist_mat, 1, function(d) sort(d)[1:nearest_n]))

# Build a long-format dataframe with nearest POIs per station
nearest_df <- tibble(
  station_id      = rep(stations$station_id, each = nearest_n),
  poi_idx         = as.vector(t(nearest_poi_idx)),
  straight_dist_m = as.vector(t(nearest_poi_dist))
) %>%
  mutate(poi_id = poi$poi_id[poi_idx]) %>%
  left_join(
    stations %>% rename(st_lon = lon, st_lat = lat),
    by = "station_id"
  ) %>%
  left_join(
    poi %>% rename(poi_lon = lon, poi_lat = lat),
    by = "poi_id"
  )

# Add station row index for chunking
nearest_df <- nearest_df %>%
  mutate(station_row = match(station_id, unique(station_id)))

# --- PART 1: GET DRIVING DISTANCE FROM OPENROUTESERVICE API ---

chunk_size <- 10  # Process 10 stations at a time to avoid too large requests

# Split the data into chunks by station_row
station_chunks <- split(
  nearest_df,
  (nearest_df$station_row - 1) %/% chunk_size
)

chunk_ids <- names(station_chunks)

# Function to call OpenRouteService matrix API to get driving distances between stations and POIs
get_matrix_distances <- function(chunk) {
  uniq_poi <- chunk %>% distinct(poi_id, poi_lon, poi_lat)
  
  # Combine stations and POIs coordinates for matrix request
  locs <- bind_rows(
    chunk %>% distinct(station_id, st_lon, st_lat) %>% select(lon = st_lon, lat = st_lat),
    uniq_poi %>% select(lon = poi_lon, lat = poi_lat)
  ) %>% as.matrix()
  
  n_st  <- nrow(chunk %>% distinct(station_id))
  n_poi <- nrow(uniq_poi)
  
  # Request distance matrix from ORS API (driving-car profile)
  m <- ors_matrix(
    locations     = locs,
    sources       = 0:(n_st - 1),              # station indices as sources
    destinations  = n_st:(n_st + n_poi - 1),  # POI indices as destinations
    profile       = "driving-car",
    metrics       = "distance",
    units         = "m"
  )
  
  # Construct results dataframe: each station to each POI with driving distance in meters
  expand.grid(st_i = seq_len(n_st), poi_j = seq_len(n_poi)) %>%
    mutate(distance_m = as.vector(m$distances)) %>%
    left_join(chunk %>% distinct(station_id) %>% mutate(st_i = row_number()), by = "st_i") %>%
    left_join(uniq_poi %>% mutate(poi_j = row_number()), by = "poi_j") %>%
    select(station_id, poi_id, distance_m)
}

# Folder to save partial results
output_folder <- "partial_results_highway"
dir.create(output_folder, showWarnings = FALSE, recursive = TRUE)

# File tracking which chunks are done
done_chunks_file <- file.path(output_folder, "done_chunks.csv")

# Read already finished chunks if any
if (file.exists(done_chunks_file)) {
  done_chunks <- read.csv(done_chunks_file, stringsAsFactors = FALSE)$chunk_id
} else {
  done_chunks <- character(0)
}

# Safe call wrapper to handle errors without stopping the loop
safe_get_matrix_distances <- function(chunk) {
  tryCatch({
    get_matrix_distances(chunk)
  }, error = function(e) {
    message("request error: ", e$message)
    return(NULL)
  })
}

pb <- progress_bar$new(total = length(station_chunks))  # progress bar

# Loop through chunks, skipping already done ones
for (chunk_id in chunk_ids) {
  if (chunk_id %in% done_chunks) {
    message(paste("skip finished chunk:", chunk_id))
    pb$tick()
    next
  }
  
  chunk <- station_chunks[[chunk_id]]
  Sys.sleep(2)  # Pause between requests
  
  res <- safe_get_matrix_distances(chunk)
  
  if (!is.null(res)) {
    save_path <- file.path(output_folder, paste0("chunk_", chunk_id, ".csv"))
    write_csv(res, save_path)  # Save partial results
    
    done_chunks <- c(done_chunks, chunk_id)
    write.csv(data.frame(chunk_id = done_chunks), done_chunks_file, row.names = FALSE)
  }
  
  pb$tick()
}

# Combine all chunk files into one final dataframe
all_files <- list.files(output_folder, pattern = "^chunk_.*\\.csv$", full.names = TRUE)
all_distances <- bind_rows(lapply(all_files, read_csv))

# Select the closest POI per station, excluding zero distances (usually itself)
final_results <- all_distances %>%
  filter(distance_m != 0) %>%
  group_by(station_id) %>%
  slice_min(distance_m, n = 1) %>%
  ungroup()

# Save final results
# write.csv(final_results, "E:/tankerkoenig-data/station_nearest_highway_drive.csv", row.names = FALSE)  

# tips:
# Change the POI and output_folder paths, then run the above code 4 times to obtain the driving distances 
# for airport, highway, train, and city respectively, and finally save them as four separate CSV files




