library(shiny)
library(shinydashboard)
library(shinyjs)
library(sf)
library(readr)
library(dplyr)
library(here)

# Outside the UI block — compute default departure time
now <- Sys.time()
rounded <- as.POSIXct(ceiling(as.numeric(now) / (30 * 60)) * (30 * 60),
                      origin = "1970-01-01", tz = "CET")
default_time <- format(rounded, "%H:%M")


ui <- dashboardPage(
  dashboardHeader(title = "Route Planner"),
  dashboardSidebar(
    width = 280,
    textInput("origin", "Origin:", placeholder = "Enter origin", value = "Dresden"),
    textInput("destination", "Destination:", placeholder = "Enter destination"),

    selectInput("departTime", "Departure Time: ",
                choices = format(seq.POSIXt(
                  from = as.POSIXct("00:00", format = "%H:%M"),
                  to   = as.POSIXct("23:30", format = "%H:%M"),
                  by   = "30 mins"), "%H:%M"),
                selected = default_time),
    dateInput("departDate", "Departure Date:", format = "yyyy-mm-dd"),

    actionButton("routeBtn", "Show Routes"),

    checkboxInput("showStations", "Show Gas Stations", value = FALSE),

    selectInput("fuel_type",
                label = "Select your fuel type:",
                choices = c("Select..." = "", "Diesel" = "diesel", "E5" = "e5", "E10" = "e10")),

    selectInput("refueling_times",
                label = "How many times will you refuel?",
                choices = c("Select..." = "", "1", "2", "3", "4", "5")),

    actionButton("generateRefuelRouteBtn", "Show Route with Refuel Stops"),
    actionButton("clearRefuelBtn", "Clear Refuel Route")
  ),
  dashboardBody(
    tags$head(
      # Google Maps API Key
      tags$script(src = paste0("https://maps.googleapis.com/maps/api/js?key=", Sys.getenv("GOOGLE_MAPS_API_KEY"))),
      tags$style(HTML("
        #map { height: 600px; width: 100%; }
        #route-info { margin-top: 10px; font-size: 16px; font-weight: bold; }
        #refuel-info { margin-top: 10px; font-size: 16px; font-weight: bold; }
      "))
    ),
    fluidRow(
      box(width = 8, div(id = "map")),
      box(width = 4,
          htmlOutput("routeDetails"),
          htmlOutput("refuelRouteInfo")
          )
    ),
    tags$script(HTML("
      let map, directionsService;
      let polylines = [];
      let originInput, destInput;
      let originMarker, destinationMarker;
      let placesService;
      let gasStationMarkers = [];
      let recommendedStationMarkers = [];
      let refuelPolylines = [];
      let refuelMarkers = [];

      function initMap() {
        directionsService = new google.maps.DirectionsService();
        map = new google.maps.Map(document.getElementById('map'), {
          center: { lat: 52.52, lng: 13.405 },
          zoom: 6
        });

        // highlight traffic highways, 2 rows below to highlight the highways
        const trafficLayer = new google.maps.TrafficLayer();
        trafficLayer.setMap(map);

        placesService = new google.maps.places.PlacesService(map);

        originInput = document.getElementById('origin');
        destInput = document.getElementById('destination');

        new google.maps.places.Autocomplete(originInput);
        new google.maps.places.Autocomplete(destInput);

        const originAutocomplete = new google.maps.places.Autocomplete(originInput);
        originAutocomplete.addListener('place_changed', () => {
          const place = originAutocomplete.getPlace();
          if (place.geometry) {
            const lat = place.geometry.location.lat();
            const lng = place.geometry.location.lng();
            Shiny.setInputValue('origin', { lat: lat, lng: lng }, { priority: 'event' });
          }
        });

        const destAutocomplete = new google.maps.places.Autocomplete(destInput);
        destAutocomplete.addListener('place_changed', () => {
          const place = destAutocomplete.getPlace();
          if (place.geometry) {
            const lat = place.geometry.location.lat();
            const lng = place.geometry.location.lng();
            Shiny.setInputValue('destination', { lat: lat, lng: lng }, { priority: 'event' });
          }
        });

      }

      function clearPolylines() {
        polylines.forEach(poly => poly.setMap(null));
        polylines = [];
        if (originMarker) originMarker.setMap(null);
        if (destinationMarker) destinationMarker.setMap(null);
        clearGasStations();
        document.getElementById('route-info').innerHTML = '';
      }

      function clearGasStations() {
        gasStationMarkers.forEach(marker => marker.setMap(null));
        gasStationMarkers = [];
      }

      function showGasStationsAlongRoute(route) {
        if (!document.getElementById('showStations').checked) return;
        clearGasStations();

        const path = route.overview_path;
        const step = Math.max(1, Math.floor(path.length / 10));

        for (let i = 0; i < path.length; i += step) {
          const location = path[i];

          const request = {
            location: location,
            radius: 8000,
            type: ['gas_station']
          };

          setTimeout(() => {
            placesService.nearbySearch(request, (results, status) => {
              if (status === google.maps.places.PlacesServiceStatus.OK) {
                results.forEach(place => {
                  const marker = new google.maps.Marker({
                    map: map,
                    position: place.geometry.location,
                    icon: {
                      url: 'https://maps.google.com/mapfiles/ms/icons/gas.png',
                      scaledSize: new google.maps.Size(32, 32)
                    },
                    title: place.name
                  });
                  gasStationMarkers.push(marker);
                });
              }
            });
          }, i * 300);
        }
      }

      function calculateAndDisplayRoute() {
        const origin = originInput.value;
        const destination = destInput.value;

        if (!destination) {
          destInput.style.border = '2px solid red';
          destInput.placeholder = 'Please enter a destination';
          return;
        }
        setTimeout(() => {
          destInput.style.border = '';
          destInput.placeholder = 'Enter destination';
        }, 1000);

        directionsService.route({
          origin: origin,
          destination: destination,
          travelMode: google.maps.TravelMode.DRIVING,
          provideRouteAlternatives: true
        }, (response, status) => {
          if (status === 'OK') {
            clearPolylines();

            const bounds = new google.maps.LatLngBounds();

            response.routes.forEach((route, i) => {

            // number of turns
            let steps = route.legs[0].steps;
            let turnKeywords = ['turn-left', 'turn-right', 'fork-left', 'fork-right', 'ramp-left', 'ramp-right', 'merge'];
            let turnCount = steps.filter(step => step.maneuver && turnKeywords.includes(step.maneuver)).length;

            if (i === 0) {
              Shiny.setInputValue('routeTurnCount', turnCount, {priority: 'event'});
            }

              const path = route.overview_path;
              const polyline = new google.maps.Polyline({
                path: path,
                strokeColor: i === 0 ? '#1E90FF' : '#A9A9A9',
                strokeOpacity: i === 0 ? 1.0 : 0.8,
                strokeWeight: i === 0 ? 8 : 6,
                map: map,
                clickable: true,
                zIndex: i === 0 ? 10 : 5
              });

              polyline.routeIndex = i;
              polyline.routeData = route;

              polyline.addListener('click', () => {
                highlightRoute(i, response.routes.length);
              });

              polylines.push(polyline);
              path.forEach(latlng => bounds.extend(latlng));
            });

            const leg = response.routes[0].legs[0];
            originMarker = new google.maps.Marker({
              position: leg.start_location,
              map: map,
              label: { text: 'A', color: 'white', fontWeight: 'bold' }
            });
            destinationMarker = new google.maps.Marker({
              position: leg.end_location,
              map: map,
              label: { text: 'B', color: 'white', fontWeight: 'bold' }
            });

            map.fitBounds(bounds);
            highlightRoute(0, response.routes.length);

            // pass the lat,lng to shiny
            const routePath = response.overview_path.map(p => ({
              lat: p.lat(),
              lng: p.lng()
            }));
            Shiny.setInputValue('routePath', routePath, {priority: 'event'});
          } else {
            alert('Route request failed due to ' + status);

          }
        });
      }

      function highlightRoute(index, totalRoutes) {
        polylines.forEach((poly, i) => {
          poly.setOptions({
            strokeColor: i === index ? '#1E90FF' : '#A9A9A9',
            strokeOpacity: i === 0 ? 1.0 : 0.8,
            strokeWeight: i === index ? 8 : 6,
            zIndex: i === index ? 10 : 5
          });
        });

        const route = polylines[index].routeData;
        const duration = route.legs[0].duration.text;
        const distance = route.legs[0].distance.text;
        const turnKeywords = ['turn-left', 'turn-right', 'fork-left', 'fork-right', 'ramp-left', 'ramp-right', 'merge'];
        const steps = route.legs[0].steps;
        const turnCount = steps.filter(step => step.maneuver && turnKeywords.includes(step.maneuver)).length;

        // Estimate duration in minutes
        let totalMinutes = 0;
        if (duration.includes('hour')) {
          const match = duration.match(/(\\d+)\\s*hour(?:s)?(?:\\s*(\\d+)\\s*min)?/);
          if (match) {
            totalMinutes += parseInt(match[1]) * 60;
            if (match[2]) totalMinutes += parseInt(match[2]);
          }
        } else {
          const minMatch = duration.match(/(\\d+)\\s*min/);
          if (minMatch) {
            totalMinutes += parseInt(minMatch[1]);
          }
        }
        // Send duration to R for arrival time calculation
        Shiny.setInputValue('routeDurationMinutes', totalMinutes, {priority: 'event'});

        // Send route path to R
        Shiny.setInputValue('routePath', route.overview_path.map(p => ({
          lat: p.lat(),
          lng: p.lng()
        })), {priority: 'event'});

        // Update right panel display
        document.getElementById('route-info').innerHTML =
          `<b>Available routes: ${totalRoutes}</b><br><br>` +
          `<b>Route ${index + 1}:</b><br>` +
          `Duration: ${duration}<br>` +
          `Distance: ${distance}<br>`+
          `Number of turns: ${turnCount}`;

        showGasStationsAlongRoute(route);

      }

      document.addEventListener('DOMContentLoaded', function() {
        initMap();

        Shiny.addCustomMessageHandler('routeRequest', function(msg) {
          calculateAndDisplayRoute();
        });
      });

      // show/hide gasstations according to checkbox
      document.getElementById('showStations').addEventListener('change', () => {
        // highlight selected route
        if (polylines.length > 0) {
          const selectedIndex = polylines.findIndex(poly => poly.strokeColor === '#1E90FF');
          highlightRoute(selectedIndex >= 0 ? selectedIndex : 0, polylines.length);
        }
      });

      // initialize stationMarkers
      if (typeof stationMarkers === 'undefined') {
        var stationMarkers = [];
      }

      Shiny.addCustomMessageHandler('plotStations', function(stations) {
        try {
          // clear old station markers
          stationMarkers.forEach(function(marker) {
            marker.setMap(null);
          });
          stationMarkers = [];

          if (!stations || stations.length === 0) {
            console.log('No stations to plot.');
            return;
          }

          // loop for each station, create a marker
          stations.forEach(function(st) {
            const lat = parseFloat(st.lat);
            const lng = parseFloat(st.lng);
            if (isNaN(lat) || isNaN(lng)) {
              console.warn('Invalid station coordinates:', st);
              return;
            }

            const marker = new google.maps.Marker({
              position: { lat: lat, lng: lng },
              map: map,
              icon: {
                path: google.maps.SymbolPath.CIRCLE,
                scale: 7,
                fillColor: 'yellow',
                fillOpacity: 0.9,
                strokeWeight: 1,
                strokeColor: 'orange'
              },
              title: st.name || 'Unnamed Station'
            });

            stationMarkers.push(marker);
          });

          console.log('Plotted', stationMarkers.length, 'stations.');
        } catch (e) {
          console.error('Error in plotStations handler:', e);
        }
      });


      Shiny.addCustomMessageHandler('plotRecommendedStations', function(stations) {
        try {
          recommendedStationMarkers.forEach(function(marker) {
            marker.setMap(null);
          });
          recommendedStationMarkers = [];

          stations.forEach(function(st) {
            const lat = parseFloat(st.lat);
            const lng = parseFloat(st.lng);

            const marker = new google.maps.Marker({
              position: { lat: lat, lng: lng },
              map: map,
              icon: {
                path: google.maps.SymbolPath.BACKWARD_CLOSED_ARROW,
                scale: 6,
                fillColor: '#FF9800',
                fillOpacity: 0.95,
                strokeWeight: 1,
                strokeColor: 'black'
              },
              title: st.name || 'Recommended Station'
            });

            const infoContent = `
              <div>
                <strong>${st.name || 'Recommended Station'}</strong><br>
                ${st.arrival ? st.arrival + '<br>' : ''}
                ${st.price ? 'Price: ' + st.price + '<br>' : ''}
                ${st.lat && st.lng ? 'Location: ' + st.lat.toFixed(5) + ', ' + st.lng.toFixed(5) : ''}
              </div>
            `;

            const infoWindow = new google.maps.InfoWindow({
              content: infoContent
            });

            marker.addListener('click', function() {
              infoWindow.open(map, marker);
            });

            recommendedStationMarkers.push(marker);
          });
        } catch (e) {
          console.error('Error plotting recommended stations:', e);
        }
      });


      Shiny.addCustomMessageHandler('drawRouteWithStops', function(data) {
        const directionsService = new google.maps.DirectionsService();

        refuelPolylines.forEach(poly => poly.setMap(null));
        refuelPolylines = [];

        refuelMarkers.forEach(marker => marker.setMap(null));
        refuelMarkers = [];

        const waypoints = data.stations.map(st => ({
          location: new google.maps.LatLng(st.lat, st.lng),
          stopover: true
        }));

        directionsService.route({
          origin: data.origin,
          destination: data.destination,
          waypoints: waypoints,
          optimizeWaypoints: true,
          travelMode: google.maps.TravelMode.DRIVING
        }, function(result, status) {
          if (status === 'OK') {
            const route = result.routes[0];
            const path = route.overview_path;

            const polyline = new google.maps.Polyline({
              path: path,
              strokeColor: '#FF8C00',
              strokeOpacity: 0.9,
              strokeWeight: 4,
              map: map,
              zIndex: 9999
            });

            refuelPolylines.push(polyline);

            const bounds = new google.maps.LatLngBounds();
            path.forEach(point => bounds.extend(point));
            map.fitBounds(bounds);

            const legs = route.legs;
            let totalDistance = 0;
            let totalDuration = 0;

            legs.forEach(leg => {
              totalDistance += leg.distance.value;
              totalDuration += leg.duration.value;
            });

            const distanceKm = (totalDistance / 1000).toFixed(1);

            const totalDurationMinutes = Math.round(totalDuration / 60);
            const hours = Math.floor(totalDurationMinutes / 60);
            const minutes = totalDurationMinutes % 60;
            const formattedDuration = hours > 0
              ? `${hours}h ${minutes}min`
              : `${minutes}min`;

            const refuelInfoBox = document.getElementById('refuel-info');
            if (refuelInfoBox) {
              refuelInfoBox.innerHTML =
                `<br><br></b>⛽️ <b>Refuel Route:</b><br>` +
                `Distance: ${distanceKm} km<br>` +
                `Estimated Duration: ${formattedDuration}`;
            }

          } else {
            alert('Refuel route failed: ' + status);
          }
        });
      });
      Shiny.addCustomMessageHandler('clearRefuelRoute', function(payload) {
        refuelPolylines.forEach(poly => poly.setMap(null));
        refuelPolylines = [];

        refuelMarkers.forEach(marker => marker.setMap(null));
        refuelMarkers = [];

        const refuelInfoBox = document.getElementById('refuel-info');
        if (refuelInfoBox) {
          refuelInfoBox.innerHTML = '';
        }
      });


      Shiny.addCustomMessageHandler('updateArrivalTime', function(arrival) {
        const infoBox = document.getElementById('route-info');
        infoBox.innerHTML += `<br><b>Estimated arrival time:</b> ${arrival}`;
      });

      Shiny.addCustomMessageHandler('updateStationCount', function(count) {
        const infoBox = document.getElementById('route-info');
        infoBox.innerHTML += `<br><br><b>Stations along route(within 3km):</b> ${count}`;
      });

    ")),
    htmlOutput("routeInfoDiv"),
    tags$div(id = "route-info")
  )
)


server <- function(input, output, session) {
  # load gas stations, need latitude & longitude
  station_data <- readr::read_csv(
    here("shiny", "2025-08-02-stations.csv")
  )
  station_sf <- st_as_sf(station_data, coords = c("longitude", "latitude"), crs = 4326)

  predicted_prices <- reactive({
    req(input$fuel_type)

    price_files <- list(
      diesel = here("shiny", "qt_dd_aug_corrected_final_v2.csv"),
      e5     = here("shiny", "qt_e5_aug_corrected_final_v2.csv"),
      e10    = here("shiny", "qt_e10_aug_corrected_final_v2.csv")
    )


    price_path <- price_files[[input$fuel_type]]

    if (!file.exists(price_path)) return(NULL)

    df <- read_csv(price_path)
    df$hour_full <- as.POSIXct(df$hour_full, tz = "CET")
    df
  })

  current_route_coords <- reactiveVal(NULL)
  reactive_stations_in_buffer <- reactiveVal(NULL)
  reactive_recommended_stations <- reactiveValues(stations = NULL)

  # update selected route
  observeEvent(input$routePath, {
    coords <- input$routePath
    if (!is.null(coords)) {
      current_route_coords(coords)
    }
  })

  # React to changes in 'Show Gas Stations' checkbox or updated route data
  observe({
    coords <- current_route_coords()
    show <- input$showStations

    if (is.null(coords)) return()

    # update route info
    route_mat <- matrix(coords, ncol = 2, byrow = TRUE)
    route_mat <- route_mat[, c(2, 1)]  # lng, lat

    route_line <- sf::st_linestring(route_mat)
    route_sf <- sf::st_sfc(route_line, crs = 4326)

    route_proj <- sf::st_transform(route_sf, 32632)
    buffer <- sf::st_buffer(route_proj, 3000)   # stations within 3km
    buffer_wgs84 <- sf::st_transform(buffer, 4326)

    stations_in_buffer <- station_sf[sf::st_intersects(station_sf, buffer_wgs84, sparse = FALSE), ]
    station_count <- nrow(stations_in_buffer)

    if (!isTRUE(show)) {
      session$sendCustomMessage("plotStations", list())  # clear stations
    } else{
      filtered_stations <- lapply(seq_len(nrow(stations_in_buffer)), function(i) {
        coords <- sf::st_coordinates(stations_in_buffer)[i, ]
        list(
          lat = as.numeric(coords[2]),
          lng = as.numeric(coords[1]),
          name = if ("name" %in% colnames(stations_in_buffer)) stations_in_buffer$name[i] else "Station"
        )
      })
      session$sendCustomMessage("plotStations", filtered_stations)
    }

    session$sendCustomMessage("updateStationCount", station_count)

    reactive_stations_in_buffer(stations_in_buffer)
  })

  # recommend gas stations
  observe({
    refuel_times <- as.numeric(input$refueling_times)

    if (is.na(refuel_times)) {
      session$sendCustomMessage("plotRecommendedStations", list())
      return()
    }

    req(reactive_stations_in_buffer())
    req(current_route_coords())

    stations_in_buffer <- reactive_stations_in_buffer()
    coords <- current_route_coords()
    if (is.null(coords)) return()

    route_mat <- matrix(coords, ncol = 2, byrow = TRUE)
    route_mat <- route_mat[, c(2, 1)]  # lng, lat

    route_points <- sf::st_as_sf(data.frame(
      lng = route_mat[, 1],
      lat = route_mat[, 2]
    ), coords = c("lng", "lat"), crs = 4326) %>%
      sf::st_transform(32632)

    route_coords <- sf::st_coordinates(route_points)
    step_dist <- sqrt(rowSums((diff(route_coords))^2))
    cum_dist <- c(0, cumsum(step_dist))  # cumulative dist

    # projected CRS for accurate distance
    station_proj <- sf::st_transform(stations_in_buffer, 32632)
    dist_matrix <- sf::st_distance(station_proj, route_points)
    station_to_route_index <- apply(dist_matrix, 1, function(row) which.min(as.numeric(row)))

    # Estimate arrival time
    speed_mps <- 25
    arrival_minutes <- round(cum_dist[station_to_route_index] / speed_mps / 60)

    depart_time <- as.POSIXct(paste(input$departDate, input$departTime), tz = "CET")
    station_arrival <- depart_time + lubridate::minutes(arrival_minutes)
    stations_in_buffer$arrival_time <- station_arrival

    # Match predicted fuel price for each station at estimated arrival time
    stations_in_buffer$arrival_hour <- lubridate::floor_date(station_arrival, unit = "hour")

    matched_price <- sapply(seq_along(station_arrival), function(i) {
      uuid <- stations_in_buffer$uuid[i]
      t <- lubridate::floor_date(station_arrival[i], unit = "hour")
      price <- predicted_prices() %>%
        dplyr::filter(station_id == uuid, hour_full == t) %>%
        dplyr::pull(predicted_price)
      if (length(price) == 0) Inf else price[1]
    })


    if (all(is.infinite(matched_price))) {
      showModal(modalDialog(
        title = "⚠️ Forecast Unavailable",
        "No fuel price predictions available for the selected time. Please choose a different time.",
        easyClose = TRUE,
        footer = NULL
      ))

      session$sendCustomMessage("plotRecommendedStations", list())
      return()
    }

    coords_mat <- sf::st_coordinates(stations_in_buffer)

    # KMeans
    set.seed(42)
    stations_in_buffer$cluster <- kmeans(coords_mat, centers = refuel_times)$cluster
    stations_in_buffer$predicted_price <- matched_price

    # cluster by dist, select the min price
    top_n <- stations_in_buffer %>%
      dplyr::filter(!is.infinite(predicted_price)) %>%
      dplyr::group_by(cluster) %>%
      dplyr::arrange(predicted_price) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup()


    recommended_stations <- lapply(seq_len(nrow(top_n)), function(i) {
      coords <- sf::st_coordinates(top_n)[i, ]
      arrival_time <- format(top_n$arrival_time[i], "%Y-%m-%d %H:%M")
      price_value <- sprintf("€%.2f/L", top_n$predicted_price[i])
      station_name <- top_n$name[i]
      list(
        lat = as.numeric(coords[2]),
        lng = as.numeric(coords[1]),
        name = station_name,
        price = price_value,
        arrival = paste("Estimated Arrival:", arrival_time),
        info = paste0("Arrival: ", arrival_time, "<br>Price: ", price_value)
      )
    })

    reactive_recommended_stations$stations <- recommended_stations

    session$sendCustomMessage("plotRecommendedStations", recommended_stations)
  })

  # present refuel route via recommended gas stations
  observeEvent(input$generateRefuelRouteBtn, {
    coords <- current_route_coords()
    origin <- input$origin
    destination <- input$destination

    if (is.null(coords)) {
      showNotification("Please select the route! ", type = "error")
      return()
    }

    stations <- reactive_recommended_stations$stations
    if (is.null(stations) || length(stations) == 0) {
      showNotification("No recommended stations available!", type = "error")
      return()
    }

    session$sendCustomMessage("drawRouteWithStops", list(
      origin = origin,
      destination = destination,
      stations = lapply(stations, function(st) {
        list(
          lat = st$lat,
          lng = st$lng,
          name = st$name,
          price = st$price,
          arrival = st$arrival,
          info = st$info
        )
      })
    ))
  })

  # Clear refuel route button
  observeEvent(input$clearRefuelBtn, {
    session$sendCustomMessage("clearRefuelRoute", list())
  })

  observe({
    req(input$routeDurationMinutes, input$departDate, input$departTime)

    depart_time <- as.POSIXct(paste(input$departDate, input$departTime), tz = "CET")
    arrival_time <- depart_time + lubridate::minutes(input$routeDurationMinutes)
    formatted_arrival <- format(arrival_time, "%Y-%m-%d %H:%M")

    # Send arrival time back to front end
    session$sendCustomMessage("updateArrivalTime", formatted_arrival)
  })

  observeEvent(input$routeBtn, {
    session$sendCustomMessage("routeRequest", list())
  })

  output$routeDetails <- renderUI({
    HTML("<div id='route-info'></div>")
  })

  output$refuelRouteInfo <- renderUI({
    HTML("<div id='refuel-info' style='margin-top:10px;'></div>")
  })
}

shinyApp(ui, server)
