library(tidyverse)
library(dplyr)

#######################################################
# PART 1: STRATIFIED SAMPLING OF STATIONS
#######################################################

set.seed(42)
total_target <- 5000  # Total number of samples (This was the number used in our first sampling attempt; 
# the final adopted sample size was 2000. Here, 5000 is used as an example to run the code)

# 1. Read station metadata
stations <- read_csv("../data/sample/2025-04-30-stations-sample.csv")  # replace with full dataset when available

# 2. Clean and normalize brand names
stations_cleaned <- stations %>%
  mutate(
    brand_clean = brand %>%
      str_to_lower() %>%
      str_replace_all("\\b(gmbh|kg|e\\.k\\.|ug|ohg|mbh)\\b", "") %>%
      str_replace_all("[[:punct:]]", " ") %>%
      str_squish() %>%
      str_replace_all("freietankstelle|frei tankstelle|freie tankstelle", "freie tankstelle") %>%
      str_squish()
  ) %>%
  mutate(brand_clean = case_when(
    str_detect(brand_clean, "freie") ~ "Freie tankstelle",
    str_detect(brand_clean, "total") ~ "Total",
    str_detect(brand_clean, "shell") ~ "Shell",
    str_detect(brand_clean, "edeka") ~ "EDEKA",
    str_detect(brand_clean, "rewe") ~ "REWE",
    str_detect(brand_clean, "ec") ~ "EC",
    str_detect(brand_clean, "sb") ~ "SB",
    str_detect(brand_clean, "hoyer") ~ "Hoyer",
    str_detect(brand_clean, "express") ~ "Express tankstelle",
    str_detect(brand_clean, "günstig") ~ "Günstig tanken",
    str_detect(brand_clean, "classic") ~ "Classic",
    str_detect(brand_clean, "bft") ~ "BFT",
    str_detect(brand_clean, "hem") ~ "HEM",
    str_detect(brand_clean, "raiffeisen") ~ "Raiffeisen",
    str_detect(brand_clean, "q1") ~ "Q1",
    str_detect(brand_clean, "oil") ~ "OIL",
    str_detect(brand_clean, "agip") ~ "Agip",
    str_detect(brand_clean, "star") ~ "Star",
    str_detect(brand_clean, "baywa") ~ "BayWa",
    str_detect(brand_clean, "orlen") ~ "ORLEN",
    str_detect(brand_clean, "\\b(ed)\\b") ~ "ED Tankstelle",
    str_detect(brand_clean, "team") ~ "Team",
    str_detect(brand_clean, "elan") ~ "Elan",
    str_detect(brand_clean, "access") ~ "Access",
    str_detect(brand_clean, "nordoel") ~ "NORDOEL",
    str_detect(brand_clean, "pm") ~ "PM",
    str_detect(brand_clean, "score") ~ "Score",
    str_detect(brand_clean, "markant") ~ "Markant",
    str_detect(brand_clean, "westfalen") ~ "Westfalen",
    str_detect(brand_clean, "sprint") ~ "Sprint",
    str_detect(brand_clean, "jet") ~ "JET",
    str_detect(brand_clean, "avia") ~ "Avia",
    str_detect(brand_clean, "esso") ~ "Esso",
    str_detect(brand_clean, "aral") ~ "Aral",
    TRUE ~ brand_clean
  )) %>%
  group_by(brand_clean) %>%
  mutate(count = n()) %>%  
  ungroup() %>%
  mutate(
    brand_clean = case_when(
      is.na(brand_clean) | brand_clean == "" ~ "Others",
      count <= 50 ~ "Others",
      count > 50 & str_detect(brand_clean, regex("frei|tankcenter", ignore_case = TRUE)) ~ "Others",
      TRUE ~ brand_clean
    )
  )

# 3. Add region classification
stations_cleaned <- stations_cleaned %>%
  mutate(
    region = case_when(
      str_detect(post_code, "^(0|1)") ~ "East",
      str_detect(post_code, "^2") ~ "North",
      str_detect(post_code, "^3") ~ "Central",
      str_detect(post_code, "^(4|5)") ~ "West",
      str_detect(post_code, "^(6|7)") ~ "Southwest",
      TRUE ~ "South"
    )
  )

# 4. Remove stations with invalid coordinates
stations_cleaned <- stations_cleaned %>%
  filter(longitude != 0, latitude != 0)

# 5. Compute target sample sizes per stratum
max_others <- round(total_target * 0.10)
strata_info <- stations_cleaned %>%
  count(region, brand_clean, name = "n") %>%
  mutate(weight = n / sum(n)) %>%
  mutate(sample_size = round(weight * total_target))

# 6. Adjust "Others" proportion if exceeding limit
others_total <- sum(strata_info$sample_size[strata_info$brand_clean == "Others"])
if (others_total > max_others) {
  strata_info <- strata_info %>%
    mutate(sample_size = if_else(
      brand_clean == "Others",
      round(sample_size / others_total * max_others),
      sample_size
    ))
}

# 7. Adjust for rounding differences
current_total <- sum(strata_info$sample_size)
diff <- total_target - current_total
if (diff != 0) {
  non_others_total <- sum(strata_info$sample_size[strata_info$brand_clean != "Others"])
  strata_info <- strata_info %>%
    mutate(sample_size = if_else(
      brand_clean != "Others",
      round(sample_size + sample_size / non_others_total * diff),
      sample_size
    ))
  final_total <- sum(strata_info$sample_size)
  if (final_total != total_target) {
    adjust_idx <- which(strata_info$brand_clean != "Others")[1]
    strata_info$sample_size[adjust_idx] <- strata_info$sample_size[adjust_idx] + (total_target - final_total)
  }
}

# 8. Perform stratified sampling
sampled_stations <- stations_cleaned %>%
  inner_join(strata_info %>% dplyr::select(region, brand_clean, sample_size),
             by = c("region", "brand_clean")) %>%
  group_by(region, brand_clean) %>%
  group_modify(~ {
    n_to_sample <- min(nrow(.x), .x$sample_size[1])
    slice_sample(.x, n = n_to_sample)
  }) %>%
  ungroup()

# 9. Keep only selected columns for joining
sampled_stations_selected <- sampled_stations %>%
  select(uuid, region, brand_clean)


#######################################################
# PART 2: PROCESS SPATIAL FEATURES
#######################################################

# 1. Read POI distance data
train   <- read.csv("E:/tankerkoenig-data/station_nearest_train_drive.csv")
airport <- read.csv("E:/tankerkoenig-data/station_nearest_airport_drive.csv")
city    <- read.csv("E:/tankerkoenig-data/station_nearest_city_drive.csv")
highway <- read.csv("E:/tankerkoenig-data/station_nearest_highway_drive.csv")

# 2. Merge all POI distances by station_id
merged <- train %>% 
  full_join(airport, by = "station_id", suffix = c("_train", "_air")) %>% 
  full_join(city,    by = "station_id", suffix = c("_train_air", "_city")) %>% 
  full_join(highway, by = "station_id", suffix = c("_train_air_city", "_hwy"))

# 3. Keep only relevant distance columns
merged_selected <- merged %>%
  select(
    station_id,
    distance_m_train,
    distance_m_air,
    distance_m_city,
    distance_m_hwy
  )


#######################################################
# PART 3: MERGE INTO FINAL STATIONS TABLE
#######################################################

stations_joined_data <- sampled_stations_selected %>%
  left_join(merged_selected, by = c("uuid" = "station_id")) %>%
  drop_na()

# Save final table
# write.csv(stations_joined_data, "E:/tankerkoenig-data/samples_station_result.csv", row.names = FALSE)
