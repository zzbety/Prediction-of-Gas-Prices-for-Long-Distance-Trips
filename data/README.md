# Data

This repository keeps **code and documentation** only. Full datasets are too large for GitHub and must be obtained separately.

## Primary source: Tankerkoenig

German nationwide fuel price data and station metadata:

- **Repository:** [tankerkoenig-data on Azure DevOps](https://dev.azure.com/tankerkoenig/_git/tankerkoenig-data)
- **Station snapshot example:** `2025-04-30-stations.csv` (metadata for ~17,000 stations)
- **Price history:** second-level price updates, aggregated to hourly features in the full pipeline

## Sample file in this repo

| File | Description |
|------|-------------|
| `sample/2025-04-30-stations-sample.csv` | First 200 rows of the April 2025 station snapshot (schema demo only) |

## External geospatial data

Driving distances to POIs (highway, airport, train station, city center) were computed with the [OpenRouteService API](https://account.heigit.org/).

## Cache tables (for Shiny app)

Nationwide hourly predictions (~60 MB+ per fuel type) are **not** committed. Regenerate them with:

1. Train structural (XGBoost) and temporal (LightGBM) models
2. Run `application/cache_table/cache_table_test.R`
3. Apply post-prediction OLS correction as described in `docs/report.tex`

Expected outputs for the Shiny app:

- `qt_diesel_aug_corrected_final_v2.csv`
- `qt_e5_aug_corrected_final_v2.csv`
- `qt_e10_aug_corrected_final_v2.csv`
- `2025-08-02-stations.csv` (station coordinates)
