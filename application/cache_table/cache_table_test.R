library(data.table)
library(lubridate)
library(xgboost)
library(mlr3)
library(here)

here()
# -- Load june &july feature dataset (includes all time-related columns) --
df_input <- data.table::fread(
  here("cache_table", "cache_test_diesel", "diesel_features_all_full.csv")
)

df_input[, hour_full := with_tz(as.POSIXct(hour, tz = "UTC"), tzone = "CET")]
df_input <- df_input[
  hour_full >= as.POSIXct("2025-06-24 00:00:00", tz = "CET") &
    hour_full <= as.POSIXct("2025-07-21 23:00:00", tz = "CET")
]

df_input[, date := as.Date(hour_full)]
df_input[, station_id := station_uuid]  # Standardize column name

# --  Rename feature columns to match LightGBM model requirements --
setnames(df_input,
         old = c("lag_1h", "lag_24h", "rollmean_6h", "rollmean_24h"),
         new = c("lag_1",  "lag_24",  "roll_mean_6",  "roll_mean_24"),
         skip_absent = TRUE)

# --  Load temporal model (LightGBM) and make predictions --
model_lgb <- readRDS(here("cache_table", "cache_test_diesel", "lrn_lightgbm.rds"))

# Extract last available hour from March as the initial feature state
last_hour <- max(df_input$hour_full)
initial_features <- df_input[hour_full == last_hour]

# Create prediction timestamp sequence for July 22-28 (hourly)
pred_hours <- seq.POSIXt(
  from = as.POSIXct("2025-07-22 00:00:00", tz = "CET"),
  to   = as.POSIXct("2025-07-28 23:00:00", tz = "CET"),
  by   = "hour"
)

# Container for storing results
pred_time_list <- list()

# Loop through each prediction timestamp
for (i in seq_along(pred_hours)) {
  t <- pred_hours[i]
  
  pred_data <- copy(initial_features)
  pred_data[, hour_full := t]
  
  # Derive time features from hour_full
  pred_data[, `:=`(
    hour         = hour(hour_full),
    wday         = wday(hour_full, week_start = 1),
    is_weekend   = as.integer(wday(hour_full, week_start = 1) %in% c(6, 7)),
    month        = month(hour_full),
    is_holiday   = 0L,
    is_peakhours = as.integer(hour(hour_full) %in% c(7:9, 16:18))
  )]
  
  # Add missing lag/rolling features if absent
  missing_cols <- setdiff(c("lag_168", "roll_mean_168", "roll_mean_72"), names(pred_data))
  for (col in missing_cols) pred_data[, (col) := NA_real_]
  
  # Model prediction
  pred_obj <- model_lgb$predict_newdata(pred_data)
  pred_data[, pred_time := pred_obj$response]
  
  # Store results
  pred_time_list[[as.character(t)]] <- pred_data[, .(station_id, hour_full, pred_time)]
}

# Combine predictions into a single data.table
df_july_pred <- rbindlist(pred_time_list)


#====== structural model part ============

# -- Prepare static model features for prediction --
stations_info <- unique(df_input[, .(station_id, brand_clean, region,
                                     distance_m_train, distance_m_air,
                                     distance_m_city, distance_m_hwy)])

# Create station-hour grid for july 22-28
hour_seq <- seq.POSIXt(as.POSIXct("2025-07-22 00:00:00", tz = "CET"),
                       as.POSIXct("2025-07-28 23:00:00", tz = "CET"),
                       by = "hour")
df_static_july <- CJ(station_id = stations_info$station_id, hour_full = hour_seq)[
  stations_info, on = "station_id"]

# Derive time features (pre-computed for speed)
hour_vals        <- hour(df_static_july$hour_full)
month_vals       <- month(df_static_july$hour_full)


df_static_july[, `:=`(
  hour        = hour_vals,
  month       = month_vals
)]

# Rename distance columns (kept identical to training features)
setnames(df_static_july,
         old = c("distance_m_train", "distance_m_air", "distance_m_city", "distance_m_hwy"),
         new = c("distance_m_train", "distance_m_air", "distance_m_city", "distance_m_hwy"),
         skip_absent = TRUE)

# -- Wrap into mlr3 Task for static model --
features_static <- c("brand_clean", "region", "distance_m_city", "distance_m_hwy",
                     "distance_m_air", "distance_m_train",
                     "hour", "month")

df_static_july[, target_dummy := 0]

task_static <- TaskRegr$new(
  id = "static_july",
  backend = df_static_july[, c(features_static, "target_dummy"), with = FALSE],
  target = "target_dummy"
)

# -- Load XGBoost static model and predict --
xgb_model <- readRDS(here("cache_table", "cache_test_diesel", "model_dxgb_pipeline.rds"))

# Get training task from pipeline
train_task <- xgb_model$state$train_task

# Sync factor levels for categorical variables
cat_cols <- train_task$col_roles$factors
for (col in cat_cols) {
  train_levels <- levels(train_task$data(cols = col)[[1]])
  df_static_july[[col]] <- factor(df_static_july[[col]], levels = train_levels)
}

# Ensure numeric columns are properly typed
num_cols <- setdiff(features_static, cat_cols)
df_static_july[, (num_cols) := lapply(.SD, function(x) as.numeric(as.character(x))), .SDcols = num_cols]

# Predict with the mlr3 pipeline
pred_static <- xgb_model$predict_newdata(df_static_july[, ..features_static])
df_static_july[, pred_static := pred_static$response]

# -- Merge predictions from both models --
final_lookup <- merge(
  df_july_pred[, .(station_id, hour_full, pred_time)],
  df_static_july[, .(station_id, hour_full, pred_static)],
  by = c("station_id", "hour_full"),
  all = TRUE
)

# Weighted average of two models (time:static = 0.75:0.25)
final_lookup[, predicted_price := 0.75 * pred_time + 0.25 * pred_static]

# -- Add metadata --
final_lookup[, prediction_date := as.Date("2025-07-22")]
final_lookup[, model_version := "v1.0"]

# -- Save lookup table --
fwrite(
  final_lookup,
  here("cache_table", "cache_table_output", "cache_table_july_test.csv")
)
cat("Lookup table generated with", nrow(final_lookup), "rows.\n")



# ============================================
# Append: Correction and Visualization Logic
# ============================================

# --- Load actual (ground truth) data ---
df_actual <- fread(here("cache_table", "cache_test_diesel", "diesel_features_all_full.csv"))
df_actual[, hour_full := with_tz(as.POSIXct(hour, tz = "UTC"), tzone = "CET")]

# Filter July 22 predictions
qt_july_22 <- final_lookup[
  hour_full >= as.POSIXct("2025-07-22 00:00:00", tz = "CET") &
    hour_full <= as.POSIXct("2025-07-22 23:00:00", tz = "CET")
]

# Rename for merging
setnames(qt_july_22, "station_id", "station_uuid")

# Merge ground truth and predictions
merged_df <- merge(
  df_actual, qt_july_22,
  by = c("station_uuid", "hour_full"),
  all.x = FALSE
)

# --- Original RMSE / MAE per station ---
rmse_df <- merged_df[, .(
  rmse = sqrt(mean((predicted_price - price)^2))
), by = .(station_uuid)]
cat("Original Mean RMSE:", rmse_df[, mean(rmse)], "\n")

mae_df <- merged_df[, .(
  mae = mean(abs(predicted_price - price))
), by = .(station_uuid)]
cat("Original Mean MAE:", mae_df[, mean(mae)], "\n")

# --- Apply linear correction ---
correction_model <- lm(price ~ predicted_price, data = merged_df)
merged_df[, corrected_pred := predict(correction_model, newdata = merged_df)]

# --- Corrected RMSE / MAE per station ---
rmse_df_corr <- merged_df[, .(
  rmse = sqrt(mean((corrected_pred - price)^2))
), by = .(station_uuid)]
cat("Corrected Mean RMSE:", rmse_df_corr[, mean(rmse)], "\n")

mae_df_corr <- merged_df[, .(
  mae = mean(abs(corrected_pred - price))
), by = .(station_uuid)]
cat("Corrected Mean MAE:", mae_df_corr[, mean(mae)], "\n")

# --- Visualization ---
library(ggplot2)

# Original error density
merged_df[, error := predicted_price - price]
p1 <- ggplot(merged_df, aes(x = error)) +
  geom_density(fill = "orange", alpha = 0.6) +
  geom_vline(xintercept = 0, color = "red", linetype = "dashed") +
  scale_x_continuous(limits = c(-0.3, 0.3)) +
  labs(title = "Original Prediction Error Density (Diesel)",
       x = "Predicted - Actual", y = "Density")

# Corrected error density
merged_df[, corrected_error := corrected_pred - price]
p2 <- ggplot(merged_df, aes(x = corrected_error)) +
  geom_density(fill = "skyblue", alpha = 0.6) +
  geom_vline(xintercept = 0, color = "red", linetype = "dashed") +
  scale_x_continuous(limits = c(-0.3, 0.3)) +
  labs(title = "Corrected Prediction Error Density (Diesel)",
       x = "Corrected Predicted - Actual", y = "Density")

# Scatter plot: actual vs predicted
p3 <- ggplot(merged_df, aes(x = price, y = predicted_price)) +
  geom_point(alpha = 0.3, size = 0.8) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "red") +
  labs(title = "Actual vs Predicted Prices",
       x = "Actual Price", y = "Predicted Price")

# Scatter plot: actual vs corrected predicted
p4 <- ggplot(merged_df, aes(x = price, y = corrected_pred)) +
  geom_point(alpha = 0.3, color = "blue", size = 0.6) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "red") +
  labs(title = "Actual vs Corrected Predicted Prices",
       x = "Actual Price", y = "Corrected Predicted Price")

# Save plots
ggsave(here("cache_table", "cache_table_output", "diesel_error_density_original.png"), p1, width = 6, height = 4)
ggsave(here("cache_table", "cache_table_output", "diesel_error_density_corrected.png"), p2, width = 6, height = 4)
ggsave(here("cache_table", "cache_table_output", "diesel_scatter_original.png"), p3, width = 6, height = 4)
ggsave(here("cache_table", "cache_table_output", "diesel_scatter_corrected.png"), p4, width = 6, height = 4)
