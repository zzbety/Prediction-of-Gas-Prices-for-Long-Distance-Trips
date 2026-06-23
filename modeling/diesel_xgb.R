## ---- diesel full ----
library(data.table)
library(dplyr)

# Full dataset: download from Tankerkoenig (see data/README.md)
dd <- fread("path/to/diesel_hourly_7-12-6_full.csv")
dd_clean <- dd[!is.na(brand_clean) & date >= "2024-07-01"]
dd_sampled <- read.csv("path/to/sampled_stations2.csv")
dd_clean <- dd_clean %>% 
  filter(station_uuid %in% dd_sampled$station_uuid) 
preprocess_numeric_columns <- function(dt) {
  price_cols <- grep("^price$", names(dt), value = TRUE)
  lag_cols <- grep("^lag_", names(dt), value = TRUE)
  roll_cols <- grep("^roll_mean_", names(dt), value = TRUE)
  distance_cols <- grep("^distance_", names(dt), value = TRUE)
  dt[, (c(price_cols, lag_cols, roll_cols)) := 
       lapply(.SD, function(x) round(as.numeric(x), 3)), .SDcols = c(price_cols, lag_cols, roll_cols)]
  dt[, (distance_cols) := 
       lapply(.SD, function(x) round(as.numeric(x) / 1000, 1)), .SDcols = distance_cols]
  return(dt)
}
dd_clean <- preprocess_numeric_columns(dd_clean)

dd_clean[, brand_clean := as.factor(brand_clean)]
dd_clean[, region := as.factor(region)]
dd_clean[, date := as.Date(date)]

######benchmark

library(mlr3)
library(mlr3learners)
library(mlr3pipelines)
library(mlr3extralearners)

#####xgboost
tsk <- TaskRegr$new("dd_clean", dd_clean, target = "price")
tsk$col_roles$feature <- setdiff(tsk$feature_names, c("station_uuid","date","lag_1", "lag_24", "lag_168", "roll_mean_6", "roll_mean_24", "roll_mean_72","roll_mean_168")) 
train_ids <- dd_clean[date <= "2025-03-31", which = TRUE]
test_ids <- dd_clean[date > "2025-03-31", which = TRUE] 

lrn.xgb <- as_learner(po("encodeimpact", affect_columns = selector_type("factor")) %>>%
                        lrn("regr.xgboost"))
lrn.xgb$train(tsk, row_ids = train_ids)
sol.xgb <- lrn.xgb$predict(tsk, row_ids = test_ids)
sol.xgb$score(msr("regr.rmse"))
lrn.xgb$importance()
sol.xgb$score(msr("regr.mae"))
pred_xgb <- as.data.table(sol.xgb)
saveRDS(lrn.xgb, file = "model_xgb_pipeline.rds")
saveRDS(pred_dt, file = "xgb_pred_dt.rds")

####decision tree
tsk_dt <- TaskRegr$new("dd_clean_dt", dd_clean, target = "price")
tsk_dt$col_roles$feature <- setdiff(tsk_dt$feature_names, 
                                    c("station_uuid","date","lag_1", "lag_24", "lag_168", 
                                      "roll_mean_6", "roll_mean_24", "roll_mean_168","roll_mean_72"))
train_ids <- dd_clean[date <= "2025-03-31", which = TRUE]
test_ids <- dd_clean[date > "2025-03-31", which = TRUE] 
lrn.tree <- lrn("regr.rpart")
lrn.tree$train(tsk_dt, row_ids = train_ids)
sol.tree <- lrn.tree$predict(tsk_dt, row_ids = test_ids)
sol.tree$score(msr("regr.rmse"))
lrn.tree$importance()
pred_tree <- as.data.table(sol.tree)
saveRDS(lrn.tree, file = "model_dtree_pipeline.rds")
saveRDS(pred_tree, file = "dtree_pred_dt.rds")

#feature selection
library(mlr3filters)
library(FSelectorRcpp)
flt <- flt("information_gain")
flt$calculate(tsk)
print(flt$scores)
top_features <- names(sort(flt$scores, decreasing = TRUE))[1:8]
tsk_fs <- tsk$clone(deep = TRUE)
tsk_fs$select(top_features)

#HPO & AutoTuner
library(paradox)
library(mlr3)
library(mlr3tuning)
library(mlr3temporal)
library(mlr3pipelines)
library(mlr3mbo)
library(mlr3temporal)
library(future)
library(DiceKriging)
library(rgenoud)
plan(multisession, workers = 4)  # 根据你的 CPU 核数设置
param_set <- ps(
  "regr.xgboost.max_depth" = p_int(lower = 4, upper = 8),
  "regr.xgboost.subsample" = p_dbl(lower = 0.6, upper = 0.9),
  "regr.xgboost.colsample_bytree" = p_dbl(lower = 0.6, upper = 0.9),
  "regr.xgboost.min_child_weight" = p_int(5, 10)
)
lrn.xgbfs <- as_learner(
  po("encodeimpact", affect_columns = selector_type("factor")) %>>%
    lrn("regr.xgboost")
)
tuned.xgb <- AutoTuner$new(
  learner = lrn.xgbfs,
  resampling = rsmp("forecast_cv",folds=3),
  measure = msr("regr.rmse"),
  search_space = param_set,
  terminator = trm("evals", n_evals = 3),
  tuner = tnr("random_search")
  #tuner = tnr("mbo")
)
tsk_train <- tsk_fs$clone()$filter(rows = train_ids)
tsk_test <- tsk_fs$clone()$filter(rows = test_ids)
tuned.xgb$train(tsk_train)
best_params <- tuned.xgb$tuning_result$learner_param_vals
tuned01 <- tuned.xgb$predict(tsk_test)
tuned01$score(msr("regr.rmse"))
tuned01$score(msr("regr.mae"))
saveRDS(tuned01, "xgbfs_prediction.rds")
saveRDS(trained_learner, "xgbfs_learner.rds")
saveRDS(tsk_train, "tuned.xgb_train.rds")
saveRDS(tsk_test, "tuned.xgb_test.rds")
saveRDS(best_params, "best_xgb_params.rds")
###IML
best_learner <- tuned.xgb$learner
library(dplyr)
library(data.table)
full_data <- as.data.table(tsk_fs$data())
full_data[, row_id := .I]
dd_clean[, row_id := .I] 
meta_data <- dd_clean[, .(row_id, station_uuid)]
full_data <- merge(full_data, meta_data, by = "row_id", all.x = TRUE)

filtered_data <- full_data[hour >= 8 & hour <= 17]

sampled_data <- filtered_data %>%
  group_by(station_uuid) %>%
  sample_frac(0.01) %>%
  ungroup() %>%
  as.data.table()

library(iml)
predict_function <- function(model, newdata) {
  as.numeric(model$predict_newdata(newdata)$response)
}
predictor <- Predictor$new(
  model = best_learner,
  data = sampled_data[, .SD, .SDcols = c("brand_clean", "region", "distance_m_air", 
                                         "distance_m_city", "distance_m_hwy", "distance_m_train", 
                                         "hour", "month")],
  y = sampled_data[[tsk_fs$target_names]],
  predict.function = predict_function
)
#feature importance
library(ggplot2)
imp <- FeatureImp$new(predictor, loss = "rmse")
imp_data <- imp$results
library(ggplot2)
ggplot(imp_data, aes(x = reorder(feature, importance), y = importance)) +
  geom_bar(stat = "identity", fill = "grey30", width = 0.6) +
  coord_flip() +
  scale_y_continuous(limits = c(1, 3), oob = scales::oob_squish) +
  labs(title = "Feature Importance (XGBoost)",
       x = NULL,
       y = "Importance") +
  theme_minimal(base_family = "serif") +
  theme(
    plot.title = element_text(size = 14,, face = "bold", hjust = 0.5),
    axis.text = element_text(size = 12, color = "black"),
    axis.title.y = element_text(size = 12),
    axis.title.x = element_text(size = 12),
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(color = "grey80", linewidth = 0.3),
    panel.grid.minor = element_blank(),
    axis.ticks = element_line(color = "black"),
    axis.line = element_line(color = "black", linewidth = 0.5)
  )


#PDP
# pdp_distance <- FeatureEffect$new(predictor, feature = "distance_m_city", method = "pdp")
# pdp_distance$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on distance_m_city") +
#   ggplot2::theme_minimal()
# 
# pdp_distance2 <- FeatureEffect$new(predictor, feature = "distance_m_air", method = "pdp")
# pdp_distance2$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on distance_m_air") +
#   ggplot2::theme_minimal()
# 
# pdp_distance3 <- FeatureEffect$new(predictor, feature = "distance_m_hwy", method = "pdp")
# pdp_distance3$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on distance_m_hwy") +
#   ggplot2::theme_minimal()
# 
# pdp_distance4 <- FeatureEffect$new(predictor, feature = "distance_m_train", method = "pdp")
# pdp_distance4$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on distance_m_train") +
#   ggplot2::theme_minimal()
# 
# pdp_region <- FeatureEffect$new(predictor, feature = "region", method = "pdp")
# pdp_region$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on region") +
#   ggplot2::theme_minimal()
# 
# pdp_brand <- FeatureEffect$new(predictor, feature = "brand_clean", method = "pdp")
# pdp_brand$plot() +
#   ggplot2::ylab("Predicted Price") +
#   ggplot2::ggtitle("Partial Dependence of Price on brand_clean") +
#   ggplot2::theme_minimal()

#SHAP
# x.interest <- sampled_data[1, .SD, .SDcols = c("brand_clean", "region", 
#                                                "distance_m_air", "distance_m_city", 
#                                                "distance_m_hwy", "distance_m_train", 
#                                                "hour", "month")]
# shap <- Shapley$new(predictor, x.interest = as.data.frame(x.interest))
# plot(shap)




